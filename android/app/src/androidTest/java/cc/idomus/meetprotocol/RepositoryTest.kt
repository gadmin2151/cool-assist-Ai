package cc.idomus.meetprotocol

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.database.DatabaseErrorHandler
import android.database.sqlite.SQLiteDatabase
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyStore
import java.util.UUID
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** Separate files, database and Keystore alias prevent recovery tests touching other records. */
@RunWith(AndroidJUnit4::class)
class RepositoryTest {
    private lateinit var context: FixtureContext
    private lateinit var repository: MeetingRepository

    @Before
    fun setup() {
        context = FixtureContext(InstrumentationRegistry.getInstrumentation().targetContext)
        repository = MeetingRepository(context)
    }

    @After
    fun cleanup() {
        context.dispose()
    }

    @Test
    fun completionIsIdempotentAndDuplicateIndexCannotReplaceAudio() {
        val meeting = repository.createMeeting("QA Idempotency", AppSettings(language = "ro"))
        val pending = addFixtureSegment(repository, meeting, 0, state = SegmentState.PENDING)
        repository.addSegment(pending)
        repository.completeSegment(pending.id, "Первый сохранённый текст")
        repository.completeSegment(pending.id, "Повторный ответ не должен заменить текст")
        assertEquals(1, repository.segments(meeting.id).size)
        assertEquals("Первый сохранённый текст", repository.segments(meeting.id).single().text)
        assertEquals("ro", repository.language(meeting.id))
        assertThrows(IllegalArgumentException::class.java) {
            repository.addSegment(pending.copy(id = UUID.randomUUID().toString()))
        }
        assertEquals(pending.id, repository.segments(meeting.id).single().id)
    }

    @Test
    fun durationCannotShrinkAndInterruptedCaptureCanBeRecovered() {
        val meeting = repository.createMeeting("QA Recovery", AppSettings())
        val segment = addFixtureSegment(repository, meeting, 0)
        repository.setCapture(meeting.id, CaptureState.RECORDING, 10_000)
        repository.setCapture(meeting.id, CaptureState.PAUSED, 5_000)
        assertEquals(10_000L, repository.meeting(meeting.id)!!.durationMs)
        assertThrows(IllegalArgumentException::class.java) { repository.deleteMeeting(meeting.id) }
        assertTrue(File(segment.audioPath).isFile)
        repository.setProcessing(meeting.id, ProcessState.TRANSCRIBING)
        repository.recoverInterrupted()
        val recovered = repository.meeting(meeting.id)!!
        assertEquals(CaptureState.INTERRUPTED, recovered.capture)
        assertEquals(ProcessState.IDLE, recovered.processing)
        assertTrue(recovered.error.isNotBlank())
        assertTrue(File(segment.audioPath).isFile)
    }

    @Test
    fun summaryRequiresCurrentGenerationCompleteTranscriptAndUnpausedQueue() {
        val meeting = repository.createMeeting("QA Generations", AppSettings())
        val pending = addFixtureSegment(repository, meeting, 0, state = SegmentState.PENDING)
        val brief = Brief("QA Grounded summary", emptyList(), emptyList(), emptyList(), emptyList())
        repository.requestSummary(meeting.id, "gpt-5.4")
        val old = repository.summaryGeneration(meeting.id)
        repository.requestSummary(meeting.id, "gpt-4.1")
        val current = repository.summaryGeneration(meeting.id)
        assertTrue(current > old)
        assertFalse(repository.saveSummaryIfCurrent(meeting.id, old, brief))
        assertFalse(repository.saveSummaryIfCurrent(meeting.id, current, brief))
        repository.completeSegment(pending.id, "QA Finished transcript")
        repository.pauseProcessing(meeting.id, "QA paused")
        assertFalse(repository.saveSummaryIfCurrent(meeting.id, current, brief))
        repository.resumeProcessing(meeting.id)
        repository.setCapture(meeting.id, CaptureState.RECORDING, 1000)
        assertFalse(repository.saveSummaryIfCurrent(meeting.id, current, brief))
        repository.setCapture(meeting.id, CaptureState.STOPPED, 1000)
        assertTrue(repository.saveSummaryIfCurrent(meeting.id, current, brief))
        assertEquals(brief, repository.meeting(meeting.id)!!.summary)
        assertFalse(repository.meeting(meeting.id)!!.summaryRequested)
    }

    @Test
    fun deletionCascadesOwnedDataAndLateSaveCannotResurrectMeeting() {
        val meeting = repository.createMeeting("QA Delete", AppSettings())
        val segment = addFixtureSegment(repository, meeting, 0)
        repository.addTask(meeting.id, "QA Remove with parent")
        val brief = Brief("QA Result", emptyList(), emptyList(), emptyList(), emptyList())
        repository.requestSummary(meeting.id, "gpt-5.4")
        val generation = repository.summaryGeneration(meeting.id)
        repository.cacheBrief(meeting.id, "qa-key", brief)
        repository.deleteMeeting(meeting.id)
        assertNull(repository.meeting(meeting.id))
        assertTrue(repository.segments(meeting.id).isEmpty())
        assertTrue(repository.tasks().none { it.meetingId == meeting.id })
        assertFalse(File(segment.audioPath).exists())
        assertNull(repository.cachedBrief(meeting.id, "qa-key"))
        assertFalse(repository.saveSummaryIfCurrent(meeting.id, generation, brief))
        repository.saveNotes(meeting.id, "QA Late notes")
        assertNull(repository.meeting(meeting.id))
    }

    @Test
    fun audioMustRemainInsideItsMeetingDirectory() {
        val meeting = repository.createMeeting("QA Boundaries", AppSettings())
        val other = repository.createMeeting("QA Other", AppSettings())
        val foreign = addFixtureSegment(repository, other, 0)
        assertThrows(IllegalArgumentException::class.java) {
            repository.addSegment(
                foreign.copy(id = UUID.randomUUID().toString(), meetingId = meeting.id)
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            repository.meetingDirectory("../../outside")
        }
        repository.deleteMeeting(meeting.id)
        assertTrue(File(foreign.audioPath).isFile)
        assertNotNull(repository.meeting(other.id))
    }

    @Test
    fun reconfiguredTranscriptionRejectsOldResultAndKeepsCompletedSegments() {
        val meeting = repository.createMeeting("QA Reconfigure", AppSettings(language = "ru"))
        val done = addFixtureSegment(repository, meeting, 0, "QA Completed original")
        val pending = addFixtureSegment(repository, meeting, 1, state = SegmentState.PENDING)
        val oldGeneration = repository.transcriptionGeneration(meeting.id)
        repository.reconfigurePending(
            meeting.id,
            AppSettings(transcriptionModel = "gpt-4o-transcribe", language = "ro"),
        )
        val currentGeneration = repository.transcriptionGeneration(meeting.id)
        assertTrue(currentGeneration > oldGeneration)
        assertFalse(
            repository.completeSegmentIfCurrent(pending, oldGeneration, "QA Stale response")
        )
        assertEquals(SegmentState.PENDING, repository.segments(meeting.id).last().state)
        assertTrue(
            repository.completeSegmentIfCurrent(pending, currentGeneration, "QA Current response")
        )
        assertEquals(done.text, repository.segments(meeting.id).first().text)
        assertEquals("QA Current response", repository.segments(meeting.id).last().text)
        assertEquals("ro", repository.language(meeting.id))
    }

    @Test
    fun queuedSummaryModelDoesNotRelabelPreviouslyGeneratedBrief() {
        val meeting =
            repository.createMeeting("QA Model provenance", AppSettings(summaryModel = "gpt-4.1"))
        addFixtureSegment(repository, meeting, 0)
        val oldBrief =
            Brief("QA Old preserved summary", emptyList(), emptyList(), emptyList(), emptyList())
        repository.saveSummary(meeting.id, oldBrief)
        repository.requestSummary(meeting.id, "gpt-5.4")
        repository.setProcessing(meeting.id, ProcessState.ERROR, "QA Simulated new-model error")
        val retained = repository.meeting(meeting.id)!!
        assertEquals(oldBrief, retained.summary)
        assertEquals("gpt-4.1", retained.generatedSummaryModel)
        assertEquals("gpt-5.4", retained.summaryModel)
        val newBrief = oldBrief.copy(introduction = "QA New result")
        assertTrue(
            repository.saveSummaryIfCurrent(
                meeting.id,
                repository.summaryGeneration(meeting.id),
                newBrief,
            )
        )
        assertEquals("gpt-5.4", repository.meeting(meeting.id)!!.generatedSummaryModel)
    }

    @Test
    fun repeatedProposalClickDoesNotDuplicateTaskOrReopenCompletedTask() {
        val meeting = repository.createMeeting("QA Duplicate action", AppSettings())
        repository.addTask(meeting.id, "QA Send drawings", "QA Vendor", "Unconfirmed")
        val task = repository.tasks().single()
        repository.toggleTask(task.id, true)
        repository.addTask(meeting.id, "  QA Send drawings  ", " QA Vendor ", " Unconfirmed ")
        assertEquals(1, repository.tasks().size)
        assertEquals(task.id, repository.tasks().single().id)
        assertTrue(repository.tasks().single().done)
    }

    @Test
    fun liveRetriesBackOffAndStopAfterFiveFailures() {
        val meeting = repository.createMeeting("QA Retry bound", AppSettings())
        assertTrue(repository.liveRetryAllowed(meeting.id))
        repository.recordLiveFailure(meeting.id, "QA Network unavailable")
        assertFalse(repository.liveRetryAllowed(meeting.id))
        assertFalse(repository.processingPaused(meeting.id))
        repeat(4) { repository.recordLiveFailure(meeting.id, "QA Network unavailable") }
        assertTrue(repository.processingPaused(meeting.id))
        repository.resumeProcessing(meeting.id)
        assertTrue(repository.liveRetryAllowed(meeting.id))
    }

    @Test
    fun queueLeavesCompletedMeetingAloneWhenNoKeyIsConfigured() {
        val meeting = repository.createMeeting("QA No pending work", AppSettings())
        addFixtureSegment(repository, meeting, 0)
        repository.saveSummary(
            meeting.id,
            Brief("QA Already done", emptyList(), emptyList(), emptyList(), emptyList()),
        )
        ProcessingQueue(context, repository, SettingsStore(context)).enqueue(meeting.id)
        assertEquals(ProcessState.COMPLETE, repository.meeting(meeting.id)!!.processing)
        assertFalse(repository.processingPaused(meeting.id))
    }

    @Test
    fun keyIsEncryptedWithFreshNonceAndRemovedWithoutChangingModels() {
        val settings = SettingsStore(context)
        val synthetic = "fixture-" + "not-an-api-credential-0123456789"
        val preferences = context.getSharedPreferences("private_settings", Context.MODE_PRIVATE)
        settings.save(AppSettings(summaryModel = "gpt-4.1", language = "ro"), synthetic)
        val firstCiphertext = preferences.getString("key_ciphertext", null)
        val firstNonce = preferences.getString("key_iv", null)
        assertTrue(settings.read().hasKey)
        assertEquals(synthetic, settings.readKey())
        assertFalse(preferences.all.values.any { it.toString().contains(synthetic) })
        settings.save(settings.read(), synthetic)
        assertNotEquals(firstCiphertext, preferences.getString("key_ciphertext", null))
        assertNotEquals(firstNonce, preferences.getString("key_iv", null))
        assertEquals(synthetic, settings.readKey())
        settings.blockCredential()
        assertTrue(settings.credentialBlocked())
        settings.removeKey()
        assertEquals("", settings.readKey())
        assertFalse(settings.read().hasKey)
        assertFalse(settings.credentialBlocked())
        assertEquals("gpt-4.1", settings.read().summaryModel)
        assertEquals("ro", settings.read().language)
    }
}

internal fun addFixtureSegment(
    repository: MeetingRepository,
    meeting: Meeting,
    index: Int,
    text: String = "QA Synthetic transcript",
    state: SegmentState = SegmentState.DONE,
): Segment {
    val file = File(repository.meetingDirectory(meeting.id), "qa-${UUID.randomUUID()}.wav")
    // One silent 16 kHz PCM sample: a real WAV container, never submitted to an API.
    val header =
        ByteBuffer.allocate(46)
            .order(ByteOrder.LITTLE_ENDIAN)
            .put("RIFF".toByteArray())
            .putInt(38)
            .put("WAVEfmt ".toByteArray())
            .putInt(16)
            .putShort(1)
            .putShort(1)
            .putInt(16_000)
            .putInt(32_000)
            .putShort(2)
            .putShort(16)
            .put("data".toByteArray())
            .putInt(2)
            .putShort(0)
            .array()
    file.writeBytes(header)
    return Segment(
            UUID.randomUUID().toString(),
            meeting.id,
            index,
            index * 10_000L,
            (index + 1) * 10_000L,
            file.path,
            text,
            state,
        )
        .also(repository::addSegment)
}

private class FixtureContext(base: Context) : ContextWrapper(base) {
    private val token = UUID.randomUUID().toString()
    private val root = File(base.cacheDir, "qa-repository-$token").apply { mkdirs() }
    private val databases = mutableListOf<SQLiteDatabase>()
    private val preferences = mutableSetOf<String>()

    override fun getApplicationContext(): Context = this

    override fun getPackageName(): String = super.getPackageName() + ".qa." + token

    override fun getFilesDir(): File = File(root, "files").apply { mkdirs() }

    override fun getDatabasePath(name: String): File =
        File(File(root, "databases").apply { mkdirs() }, name)

    override fun openOrCreateDatabase(
        name: String,
        mode: Int,
        factory: SQLiteDatabase.CursorFactory?,
    ): SQLiteDatabase =
        SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name), factory).also(databases::add)

    override fun openOrCreateDatabase(
        name: String,
        mode: Int,
        factory: SQLiteDatabase.CursorFactory?,
        errorHandler: DatabaseErrorHandler?,
    ): SQLiteDatabase =
        SQLiteDatabase.openOrCreateDatabase(getDatabasePath(name).path, factory, errorHandler)
            .also(databases::add)

    override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
        val scoped = "qa-$token-$name"
        preferences += scoped
        return baseContext.getSharedPreferences(scoped, mode)
    }

    fun dispose() {
        databases.forEach { if (it.isOpen) it.close() }
        preferences.forEach { baseContext.deleteSharedPreferences(it) }
        KeyStore.getInstance("AndroidKeyStore").apply {
            load(null)
            deleteEntry(packageName + ".openai-key.v1")
        }
        check(root.deleteRecursively()) { "Unable to remove isolated QA files" }
    }
}
