package cc.idomus.meetprotocol

import android.Manifest
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters

/** Runs on the isolated emulator with its microphone input disabled; never sends paid API calls. */
@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class CaptureLifecycleTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context
        get() = instrumentation.targetContext

    private val graph
        get() = MeetProtocolApplication.graph(context)

    private val createdMeetings = mutableListOf<String>()
    private var scenario: ActivityScenario<MainActivity>? = null

    @Before
    fun openActivity() {
        assumeFalse("Capture tests only run without a saved API key", graph.settings.read().hasKey)
        assumeTrue(
            "Another recording must not be disturbed",
            CaptureController.status.value.meetingId == null,
        )
        scenario = ActivityScenario.launch(MainActivity::class.java)
        await { graph.ready.value }
    }

    @After
    fun cleanUpOwnFixtures() {
        if (CaptureController.status.value.meetingId in createdMeetings) {
            scenario?.onActivity { CaptureController.stop(it) }
            await { CaptureController.status.value.meetingId !in createdMeetings }
        }
        createdMeetings.forEach { id ->
            graph.queue.cancel(id)
            graph.repository.deleteMeeting(id)
        }
        scenario?.close()
    }

    @Test
    fun a_microphonePermissionFailureLeavesRecordingStopped() {
        assumeTrue(
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                PackageManager.PERMISSION_GRANTED
        )
        val meeting = createMeeting()
        scenario!!.onActivity { CaptureController.start(it, meeting.id) }
        await {
            CaptureController.status.value.meetingId == null &&
                CaptureController.status.value.warning.isNotEmpty()
        }
        assertEquals(CaptureState.STOPPED, graph.repository.meeting(meeting.id)!!.capture)
        assertTrue(graph.repository.segments(meeting.id).isEmpty())
    }

    @Test
    fun b_pauseResumeStopAndImmediateNewMeetingKeepCorrectStateAndAudio() {
        instrumentation.uiAutomation.grantRuntimePermission(
            context.packageName,
            Manifest.permission.RECORD_AUDIO,
        )
        instrumentation.uiAutomation.grantRuntimePermission(
            context.packageName,
            Manifest.permission.POST_NOTIFICATIONS,
        )
        val meeting = createMeeting()
        scenario!!.onActivity { CaptureController.start(it, meeting.id) }
        await {
            CaptureController.status.value.meetingId == meeting.id &&
                CaptureController.status.value.elapsedMs >= 300
        }
        scenario!!.onActivity { CaptureController.pause(it) }
        await { CaptureController.status.value.paused }
        val pausedDuration = CaptureController.status.value.elapsedMs
        Thread.sleep(250)
        assertEquals(pausedDuration, CaptureController.status.value.elapsedMs)
        assertEquals(CaptureState.PAUSED, graph.repository.meeting(meeting.id)!!.capture)
        assertTrue(graph.repository.segments(meeting.id).isNotEmpty())
        scenario!!.onActivity { CaptureController.resume(it) }
        await {
            !CaptureController.status.value.paused &&
                CaptureController.status.value.elapsedMs >= pausedDuration + 200
        }
        scenario!!.onActivity { CaptureController.stop(it) }
        await { CaptureController.status.value.meetingId == null }
        assertEquals(CaptureState.STOPPED, graph.repository.meeting(meeting.id)!!.capture)
        verifyAudio(meeting.id)

        // No delay here: this specifically exercises the completed-service/new-start handoff.
        val next = createMeeting()
        scenario!!.onActivity { CaptureController.start(it, next.id) }
        await {
            CaptureController.status.value.meetingId == next.id &&
                CaptureController.status.value.elapsedMs >= 200
        }
        scenario!!.onActivity { CaptureController.stop(it) }
        await { CaptureController.status.value.meetingId == null }
        assertEquals(CaptureState.STOPPED, graph.repository.meeting(next.id)!!.capture)
        verifyAudio(next.id)
    }

    @Test
    fun c_stopDuringStartupDoesNotLeaveSessionActive() {
        instrumentation.uiAutomation.grantRuntimePermission(
            context.packageName,
            Manifest.permission.RECORD_AUDIO,
        )
        val meeting = createMeeting()
        scenario!!.onActivity {
            CaptureController.start(it, meeting.id)
            CaptureController.stop(it)
        }
        await { CaptureController.status.value.meetingId == null }
        assertEquals(CaptureState.STOPPED, graph.repository.meeting(meeting.id)!!.capture)
    }

    @Test
    fun d_foregroundServiceContinuesRecordingWhileActivityIsStopped() {
        instrumentation.uiAutomation.grantRuntimePermission(
            context.packageName,
            Manifest.permission.RECORD_AUDIO,
        )
        val meeting = createMeeting()
        scenario!!.onActivity { CaptureController.start(it, meeting.id) }
        await {
            CaptureController.status.value.meetingId == meeting.id &&
                CaptureController.status.value.elapsedMs >= 200
        }
        val beforeBackground = CaptureController.status.value.elapsedMs
        scenario!!.moveToState(Lifecycle.State.CREATED)
        await(timeoutMs = 5_000) {
            CaptureController.status.value.elapsedMs >= beforeBackground + 1000
        }
        assertEquals(meeting.id, CaptureController.status.value.meetingId)
        assertFalse(CaptureController.status.value.paused)
        assertEquals(CaptureState.RECORDING, graph.repository.meeting(meeting.id)!!.capture)
        scenario!!.moveToState(Lifecycle.State.RESUMED)
        scenario!!.onActivity { CaptureController.stop(it) }
        await { CaptureController.status.value.meetingId == null }
        assertEquals(CaptureState.STOPPED, graph.repository.meeting(meeting.id)!!.capture)
        assertTrue(graph.repository.meeting(meeting.id)!!.durationMs >= beforeBackground + 1000)
        verifyAudio(meeting.id)
    }

    private fun createMeeting() =
        graph.repository.createMeeting("Capture lifecycle fixture", AppSettings()).also {
            createdMeetings.add(it.id)
        }

    private fun verifyAudio(id: String) {
        val segments = graph.repository.segments(id)
        assertFalse(segments.isEmpty())
        segments.forEach { segment ->
            val file = File(segment.audioPath)
            assertTrue(file.isFile)
            assertTrue(WavWriter.sampleCount(file) > 0)
            assertTrue(segment.endMs >= segment.startMs)
        }
        segments.zipWithNext().forEach { (left, right) -> assertEquals(left.endMs, right.startMs) }
        assertFalse(
            graph.repository.meetingDirectory(id).listFiles().orEmpty().any {
                it.name.endsWith(".part")
            }
        )
    }

    private fun await(timeoutMs: Long = 15_000, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (!condition()) {
            if (SystemClock.uptimeMillis() >= deadline)
                throw AssertionError(
                    "Capture state did not converge: ${CaptureController.status.value}"
                )
            Thread.sleep(50)
        }
    }
}
