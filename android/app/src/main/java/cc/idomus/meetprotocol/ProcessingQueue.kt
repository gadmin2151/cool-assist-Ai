package cc.idomus.meetprotocol

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Persist intent in SQLite first; WorkManager wakeups may be duplicated without losing data. */
class ProcessingQueue(
    context: Context,
    private val repository: MeetingRepository,
    private val settings: SettingsStore,
) {
    private val appContext = context.applicationContext
    private val work = WorkManager.getInstance(context.applicationContext)

    @Synchronized
    fun enqueue(id: String, continueDrain: Boolean = false) {
        val meeting = repository.meeting(id) ?: return
        if (repository.processingPaused(id)) return
        if (
            !meeting.summaryRequested &&
                repository.segments(id).none { it.state == SegmentState.PENDING }
        )
            return
        if (!settings.read().hasKey || settings.credentialBlocked()) {
            repository.pauseProcessing(
                id,
                "Добавьте или проверьте API-ключ в настройках, затем нажмите «Повторить». Аудио сохраняется.",
                "credential",
            )
            return
        }
        val request =
            OneTimeWorkRequestBuilder<MeetingProcessingWorker>()
                .setInputData(workDataOf(MEETING_ID to id))
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
                )
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .addTag(TAG)
                .addTag(name(id))
                .build()
        // The foreground service's conflated channel supplies live wakeups. Keep one durable
        // fallback while capturing, avoiding thousands of empty jobs behind Android job quotas.
        // Stop and process-recovery always append a final drain, closing KEEP's last-chunk race.
        val policy = processingWorkPolicy(meeting.capture, continueDrain)
        work.enqueueUniqueWork(name(id), policy, request)
    }

    @Synchronized
    fun retry(id: String) {
        settings.unblockCredential()
        repository.reconfigurePending(id, settings.read())
        repository.resumeProcessing(id)
        enqueue(id)
    }

    @Synchronized
    fun requestSummary(id: String, model: String) {
        repository.requestSummary(id, model)
        repository.resumeProcessing(id)
        enqueue(id)
    }

    @Synchronized
    fun cancel(id: String) {
        repository.pauseProcessing(
            id,
            "Обработка приостановлена. Запись и готовые результаты сохранены.",
            "user",
        )
        work.cancelUniqueWork(name(id))
    }

    @Synchronized
    fun cancelAll() {
        repository.meetings().filter(::hasPendingWork).forEach {
            repository.pauseProcessing(
                it.id,
                "Обработка приостановлена. Добавьте API-ключ для продолжения.",
                "credential",
            )
        }
        work.cancelAllWorkByTag(TAG)
    }

    @Synchronized
    fun resumeAll() {
        repository
            .meetings()
            .filter { !repository.processingPaused(it.id) }
            .forEach { enqueue(it.id) }
    }

    @Synchronized
    fun resumeAfterSettingsChange() {
        settings.unblockCredential()
        repository
            .meetings()
            .filter { hasPendingWork(it) && repository.pauseReason(it.id) != "user" }
            .forEach { retry(it.id) }
    }

    private fun hasPendingWork(meeting: Meeting) =
        meeting.summaryRequested ||
            meeting.processing == ProcessState.TRANSCRIBING ||
            meeting.processing == ProcessState.SUMMARIZING ||
            repository.segments(meeting.id).any { it.state == SegmentState.PENDING }

    /** Called from the active microphone service's coroutine, avoiding JobScheduler live quotas. */
    suspend fun drainWhileRecording(id: String) =
        withContext(Dispatchers.IO) {
            val graph = MeetProtocolApplication.graph(appContext)
            if (withTimeoutOrNull(30_000) { graph.ready.first { it } } == null) return@withContext
            meetingMutex(id).withLock {
                val meeting = repository.meeting(id) ?: return@withLock
                if (
                    meeting.capture != CaptureState.RECORDING &&
                        meeting.capture != CaptureState.PAUSED
                )
                    return@withLock
                if (!repository.liveRetryAllowed(id)) return@withLock
                try {
                    MeetingDrain(graph).process(id, allowSummary = false)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: ApiFailure) {
                    if (repository.meeting(id) == null || repository.processingPaused(id))
                        return@withLock
                    if (failure.credentialsChanged) {
                        enqueue(id)
                        return@withLock
                    }
                    if (failure.credentialFailure) settings.blockCredential()
                    if (failure.retryable)
                        repository.recordLiveFailure(id, failure.message.orEmpty())
                    else
                        repository.pauseProcessing(
                            id,
                            failure.message.orEmpty(),
                            if (failure.credentialFailure) "credential" else "error",
                        )
                } catch (_: Exception) {
                    if (repository.meeting(id) != null && !repository.processingPaused(id)) {
                        repository.pauseProcessing(
                            id,
                            "Не удалось распознать аудио. Исходная запись сохранена; проверьте настройки и свободное место.",
                        )
                    }
                }
            }
        }

    companion object {
        private val mutexes = ConcurrentHashMap<String, Mutex>()

        internal fun meetingMutex(id: String): Mutex = mutexes.getOrPut(id) { Mutex() }

        internal const val MEETING_ID = "meeting_id"
        private const val TAG = "meeting-processing"

        private fun name(id: String): String {
            MeetingRepository.validateID(id)
            return "meeting-$id"
        }
    }
}

class MeetingProcessingWorker(context: Context, parameters: WorkerParameters) :
    CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result =
        withContext(Dispatchers.IO) {
            val id =
                inputData.getString(ProcessingQueue.MEETING_ID)
                    ?: return@withContext Result.failure()
            if (runCatching { MeetingRepository.validateID(id) }.isFailure)
                return@withContext Result.failure()
            val graph = MeetProtocolApplication.graph(applicationContext)
            // Application audio repair must finish before a restored WorkManager task reads a file.
            if (withTimeoutOrNull(30_000) { graph.ready.first { it } } == null)
                return@withContext Result.retry()
            val repository = graph.repository
            if (repository.meeting(id) == null || repository.processingPaused(id))
                return@withContext Result.success()
            try {
                val finished =
                    withTimeoutOrNull(8 * 60_000L) {
                        ProcessingQueue.meetingMutex(id).withLock {
                            MeetingDrain(graph).process(id)
                        }
                        true
                    } ?: false
                if (!finished) {
                    return@withContext retryOrPause(
                        repository,
                        id,
                        "Обработка продолжится с сохранённого места.",
                    )
                }
                Result.success()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: ApiFailure) {
                if (repository.meeting(id) == null || repository.processingPaused(id))
                    return@withContext Result.success()
                if (failure.credentialsChanged) {
                    graph.queue.enqueue(id)
                    return@withContext Result.success()
                }
                if (failure.credentialFailure) graph.settings.blockCredential()
                if (failure.retryable) retryOrPause(repository, id, failure.message.orEmpty())
                else {
                    repository.pauseProcessing(
                        id,
                        failure.message.orEmpty(),
                        if (failure.credentialFailure) "credential" else "error",
                    )
                    Result.failure()
                }
            } catch (_: Exception) {
                if (repository.meeting(id) != null && !repository.processingPaused(id)) {
                    repository.pauseProcessing(
                        id,
                        "Не удалось обработать материалы. Аудио и готовый текст сохранены; проверьте ключ, модель и свободное место.",
                    )
                }
                Result.failure()
            }
        }

    private fun retryOrPause(repository: MeetingRepository, id: String, message: String): Result {
        if (repository.meeting(id) == null || repository.processingPaused(id))
            return Result.success()
        if (runAttemptCount < 4) {
            repository.setProcessing(
                id,
                ProcessState.ERROR,
                "$message Автоматическая попытка ${runAttemptCount + 2}/5.",
            )
            return Result.retry()
        }
        repository.pauseProcessing(
            id,
            "Автоматические попытки завершены. Проверьте интернет и настройки, затем нажмите «Повторить». Материалы сохранены.",
        )
        return Result.failure()
    }
}

private class MeetingDrain(private val graph: AppGraph) {
    suspend fun process(id: String, allowSummary: Boolean = true) {
        val repository = graph.repository
        val client = OpenAIClient()
        var processed = 0
        while (processed < 30) {
            currentCoroutineContext().ensureActive()
            val meeting = repository.meeting(id) ?: return
            if (repository.processingPaused(id)) return
            if (graph.settings.credentialBlocked())
                throw ApiFailure(
                    "Проверьте API-ключ и баланс OpenAI, затем повторите обработку.",
                    credentialFailure = true,
                )
            val segments = repository.segments(id)
            val pending = segments.firstOrNull { it.state == SegmentState.PENDING } ?: break
            val file = File(pending.audioPath).canonicalFile
            if (
                file.parentFile != repository.meetingDirectory(id).canonicalFile ||
                    file.extension != "wav"
            ) {
                throw ApiFailure(
                    "Аудиофрагмент находится вне папки встречи. Обработка остановлена."
                )
            }
            repository.setProcessing(id, ProcessState.TRANSCRIBING)
            val generation = repository.transcriptionGeneration(id)
            val context =
                segments
                    .asSequence()
                    .filter { it.index < pending.index && it.state == SegmentState.DONE }
                    .takeLastText(2_000)
            val text =
                client.transcribe(
                    graph.settings.readKey(),
                    meeting.transcriptionModel,
                    repository.language(id),
                    file,
                    context,
                    live =
                        !allowSummary ||
                            meeting.capture == CaptureState.RECORDING ||
                            meeting.capture == CaptureState.PAUSED,
                )
            currentCoroutineContext().ensureActive()
            if (repository.meeting(id) == null || repository.processingPaused(id)) return
            repository.completeSegmentIfCurrent(pending, generation, text)
            processed++
        }
        val meeting = repository.meeting(id) ?: return
        if (repository.processingPaused(id)) return
        val segments = repository.segments(id)
        if (segments.any { it.state == SegmentState.PENDING }) {
            // KEEP would discard this wakeup while the current worker is still running, leaving
            // a paused recording's offline backlog stranded until another microphone chunk.
            graph.queue.enqueue(id, continueDrain = true)
            return
        }
        if (meeting.capture == CaptureState.RECORDING || meeting.capture == CaptureState.PAUSED) {
            repository.setProcessing(id, ProcessState.IDLE)
            return
        }
        if (!allowSummary || !meeting.summaryRequested) {
            repository.setProcessing(
                id,
                if (meeting.summary != null) ProcessState.COMPLETE else ProcessState.IDLE,
            )
            return
        }
        val generation = repository.summaryGeneration(id)
        repository.setProcessing(id, ProcessState.SUMMARIZING)
        val brief =
            client.summarize(
                graph.settings.readKey(),
                meeting.summaryModel,
                meeting,
                segments,
                object : SummaryCheckpoint {
                    override fun read(key: String) = repository.cachedBrief(id, key)

                    override fun write(key: String, brief: Brief) =
                        repository.cacheBrief(id, key, brief)
                },
            )
        currentCoroutineContext().ensureActive()
        if (!repository.saveSummaryIfCurrent(id, generation, brief)) graph.queue.enqueue(id)
    }
}

private fun Sequence<Segment>.takeLastText(limit: Int): String {
    val context = StringBuilder()
    for (segment in this) {
        if (context.isNotEmpty()) context.append(' ')
        context.append(segment.text)
        if (context.length > limit) context.delete(0, context.length - limit)
    }
    return context.toString()
}

internal fun processingWorkPolicy(
    capture: CaptureState,
    continueDrain: Boolean,
): ExistingWorkPolicy =
    if (!continueDrain && capture in listOf(CaptureState.RECORDING, CaptureState.PAUSED))
        ExistingWorkPolicy.KEEP
    else ExistingWorkPolicy.APPEND_OR_REPLACE
