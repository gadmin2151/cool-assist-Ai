package cc.idomus.meetprotocol

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.sqrt
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class RecordingService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var activeMeetingId: String? = null
    private var workerToken = 0L
    private var latestStartId = 0
    @Volatile private var currentStatus = CaptureStatus()
    @Volatile private var requested = Requested.RECORDING
    @Volatile private var destroyed = false

    private enum class Requested {
        RECORDING,
        PAUSED,
        STOPPED,
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(
                NotificationChannel(CHANNEL, "Запись встречи", NotificationManager.IMPORTANCE_LOW)
            )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        latestStartId = startId
        when (intent?.action) {
            ACTION_START -> {
                if (activeMeetingId != null) {
                    CaptureController.publish(currentStatus)
                    return START_NOT_STICKY
                }
                val id = intent.getStringExtra(EXTRA_MEETING_ID)
                if (
                    id == null || runCatching { UUID.fromString(id).toString() }.getOrNull() != id
                ) {
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                if (
                    checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                        PackageManager.PERMISSION_GRANTED
                ) {
                    CaptureController.publish(
                        CaptureStatus(warning = "Для записи требуется разрешение на микрофон.")
                    )
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        startForeground(
                            NOTIFICATION_ID,
                            notification(false, 0),
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                        )
                    } else startForeground(NOTIFICATION_ID, notification(false, 0))
                } catch (_: RuntimeException) {
                    CaptureController.publish(
                        CaptureStatus(
                            warning =
                                "Android не разрешил запись. Начните её из открытого приложения."
                        )
                    )
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                activeMeetingId = id
                val token = ++workerToken
                requested = Requested.RECORDING
                publishCapture(CaptureStatus(meetingId = id, warning = "Подготовка микрофона…"))
                scope.launch { recordMeeting(id, token) }
            }
            ACTION_PAUSE ->
                if (activeMeetingId != null && requested != Requested.STOPPED)
                    requested = Requested.PAUSED
            ACTION_RESUME ->
                if (activeMeetingId != null && requested != Requested.STOPPED)
                    requested = Requested.RECORDING
            ACTION_STOP -> requested = Requested.STOPPED
            else -> if (activeMeetingId == null) stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private suspend fun recordMeeting(id: String, token: Long) {
        val graph = MeetProtocolApplication.graph(this)
        var recorder: AudioRecord? = null
        var sink: WavChunkSink? = null
        var wakeLock: PowerManager.WakeLock? = null
        var callback: AudioManager.AudioRecordingCallback? = null
        val liveSignals = Channel<Unit>(Channel.CONFLATED)
        var liveDrainer: Job? = null
        var failure: Throwable? = null
        var durationMs = 0L
        var summaryModel: String? = null
        var capturing = false
        val silenced = AtomicBoolean(false)
        try {
            val meeting = graph.repository.meeting(id) ?: throw IOException("Meeting is missing")
            summaryModel = meeting.summaryModel
            val directory = graph.repository.meetingDirectory(id)
            recoverMeetingAudio(graph.repository, meeting)
            val prior = graph.repository.segments(id)
            val startingSamples =
                prior
                    .maxByOrNull { it.endMs }
                    ?.let { segment ->
                        val file = File(segment.audioPath)
                        val parsed = WavWriter.parseName(file)
                        if (
                            parsed != null &&
                                file.isFile &&
                                file.canonicalFile.parentFile == directory.canonicalFile
                        ) {
                            Math.addExact(parsed.second, WavWriter.sampleCount(file))
                        } else segment.endMs * WavWriter.SAMPLE_RATE / 1000
                    } ?: 0L
            val existingFileIndex =
                directory.listFiles()?.mapNotNull { WavWriter.parseName(it)?.first }?.maxOrNull()
                    ?: -1
            val nextIndex =
                Math.addExact(maxOf(prior.maxOfOrNull { it.index } ?: -1, existingFileIndex), 1)
            sink =
                WavChunkSink(
                    directory,
                    nextIndex,
                    startingSamples,
                    samplesPerChunk = WavWriter.SAMPLE_RATE * 14,
                    speechBoundary = SpeechChunkBoundary(),
                    onChunk = { chunk ->
                        graph.repository.addSegment(chunk.toSegment(id))
                        graph.queue.enqueue(id)
                        liveSignals.trySend(Unit)
                    },
                )
            liveDrainer =
                scope.launch { for (signal in liveSignals) graph.queue.drainWhileRecording(id) }
            durationMs = milliseconds(startingSamples)
            val minimum =
                AudioRecord.getMinBufferSize(
                    WavWriter.SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                )
            if (minimum <= 0) throw IOException("Unsupported microphone format")
            if (
                checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                    PackageManager.PERMISSION_GRANTED
            )
                throw SecurityException()
            recorder =
                AudioRecord.Builder()
                    .setAudioSource(MediaRecorder.AudioSource.MIC)
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(WavWriter.SAMPLE_RATE)
                            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                            .build()
                    )
                    .setBufferSizeInBytes(maxOf(minimum * 2, WavWriter.SAMPLE_RATE * 2))
                    .build()
            if (recorder.state != AudioRecord.STATE_INITIALIZED)
                throw IOException("Microphone unavailable")
            callback =
                object : AudioManager.AudioRecordingCallback() {
                    override fun onRecordingConfigChanged(
                        configs: MutableList<AudioRecordingConfiguration>
                    ) {
                        configs.firstOrNull()?.let { silenced.set(it.isClientSilenced) }
                    }
                }
            recorder.registerAudioRecordingCallback(mainExecutor, callback)
            wakeLock =
                getSystemService(PowerManager::class.java)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MeetProtocol:recording")
                    .apply { setReferenceCounted(false) }
            val buffer = ShortArray(WavWriter.SAMPLE_RATE / 10)
            var lastPersistence = 0L
            var lastCaptureSave = 0L
            var lastNotification = 0L
            var wakeRenewal = 0L
            var silentSamples = 0L
            var emptyReads = 0
            var pausedSaved = false
            while (scope.isActive && requested != Requested.STOPPED) {
                if (requested == Requested.PAUSED) {
                    if (capturing) {
                        recorder.stop()
                        capturing = false
                        sink.finishChunk()
                        durationMs = milliseconds(sink.totalSamples)
                    }
                    if (wakeLock.isHeld) wakeLock.release()
                    if (!pausedSaved) {
                        graph.repository.setCapture(id, CaptureState.PAUSED, durationMs)
                        publishCapture(CaptureStatus(id, true, durationMs))
                        showNotification(true, durationMs)
                        pausedSaved = true
                    }
                    delay(100)
                    continue
                }
                if (!capturing) {
                    if (
                        checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                            PackageManager.PERMISSION_GRANTED
                    )
                        throw SecurityException()
                    silenced.set(false)
                    recorder.startRecording()
                    if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING)
                        throw IOException("Microphone did not start")
                    capturing = true
                    pausedSaved = false
                    graph.repository.setCapture(id, CaptureState.RECORDING, durationMs)
                    wakeLock.acquire(WAKE_TIMEOUT_MS)
                    wakeRenewal = SystemClock.elapsedRealtime()
                    silentSamples = 0
                }
                val read = recorder.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                if (read < 0) throw IOException("Microphone read failed")
                if (read == 0) {
                    if (++emptyReads >= 30) throw IOException("Microphone returned no audio")
                    delay(20)
                    continue
                }
                emptyReads = 0
                val denied =
                    silenced.get() ||
                        recorder.activeRecordingConfiguration?.isClientSilenced == true
                if (denied) throw CaptureSilencedException()
                sink.append(buffer, read)
                durationMs = milliseconds(sink.totalSamples)
                var energy = 0.0
                for (i in 0 until read) {
                    val value = buffer[i].toDouble() / 32768
                    energy += value * value
                }
                val level = sqrt(energy / read).toFloat().coerceIn(0f, 1f)
                silentSamples = if (level < 0.001f) silentSamples + read else 0
                val warning =
                    when {
                        silentSamples >= WavWriter.SAMPLE_RATE * 20L ->
                            "Почти не слышно звука. Проверьте микрофон и расстояние до участников."
                        else -> ""
                    }
                publishCapture(CaptureStatus(id, false, durationMs, level, warning))
                val now = SystemClock.elapsedRealtime()
                if (now - lastPersistence >= 1000) {
                    sink.checkpoint()
                    lastPersistence = now
                }
                if (now - lastCaptureSave >= 5000) {
                    graph.repository.setCapture(id, CaptureState.RECORDING, durationMs)
                    lastCaptureSave = now
                }
                if (now - lastNotification >= 5000) {
                    showNotification(false, durationMs)
                    lastNotification = now
                }
                if (now - wakeRenewal >= WAKE_TIMEOUT_MS / 2) {
                    wakeLock.acquire(WAKE_TIMEOUT_MS)
                    wakeRenewal = now
                }
            }
        } catch (error: Throwable) {
            failure = error
        } finally {
            fun cleanup(action: () -> Unit) {
                try {
                    action()
                } catch (error: Exception) {
                    if (failure == null) failure = error else failure?.addSuppressed(error)
                }
            }
            if (capturing) cleanup { recorder?.stop() }
            callback?.let { registered ->
                cleanup { recorder?.unregisterAudioRecordingCallback(registered) }
            }
            cleanup { recorder?.release() }
            cleanup { if (wakeLock?.isHeld == true) wakeLock?.release() }
            cleanup { sink?.finishChunk() }
            cleanup { sink?.let { durationMs = milliseconds(it.totalSamples) } }
            liveSignals.close()
            withContext(NonCancellable) { liveDrainer?.cancelAndJoin() }
            val interrupted = failure != null || destroyed || requested != Requested.STOPPED
            cleanup {
                graph.repository.setCapture(
                    id,
                    if (interrupted) CaptureState.INTERRUPTED else CaptureState.STOPPED,
                    durationMs,
                )
            }
            if (failure == null && !interrupted && durationMs > 0) {
                cleanup { summaryModel?.let { graph.queue.requestSummary(id, it) } }
            } else cleanup { graph.queue.enqueue(id) }
            val warning =
                when {
                    failure is CaptureSilencedException ->
                        "Запись прервана: Android заглушил микрофон из-за звонка или другого приложения. Сохранённое аудио доступно во встрече."
                    failure is SecurityException ->
                        "Запись остановлена: доступ к микрофону отозван. Сохранённое аудио доступно во встрече."
                    failure is CancellationException || destroyed ->
                        "Запись прервана. Сохранённые фрагменты доступны во встрече."
                    failure != null ->
                        "Запись прервана. Проверьте микрофон и свободное место; сохранённые фрагменты доступны во встрече."
                    else -> ""
                }
            // Main-thread handoff prevents a rapid new start from hitting a completed service
            // which still considers the old meeting active. A destroyed older instance cannot
            // erase a newer instance's status because publication also checks the meeting ID.
            withContext(NonCancellable + Dispatchers.Main.immediate) {
                if (workerToken == token && activeMeetingId == id) {
                    activeMeetingId = null
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelfResult(latestStartId)
                    CaptureController.publishForMeeting(
                        id,
                        CaptureStatus(elapsedMs = durationMs, warning = warning),
                    )
                }
            }
        }
    }

    private fun publishCapture(status: CaptureStatus) {
        currentStatus = status
        status.meetingId?.let { CaptureController.publishForMeeting(it, status) }
    }

    private fun notification(paused: Boolean, elapsed: Long): Notification {
        val open =
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val stop =
            PendingIntent.getService(
                this,
                1,
                Intent(this, RecordingService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(if (paused) "Запись на паузе" else "Идёт запись встречи")
            .setContentText("${clockText(elapsed)} · Cool Assist Ai")
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .addAction(Notification.Action.Builder(null, "Остановить", stop).build())
            .build()
    }

    private fun showNotification(paused: Boolean, elapsed: Long) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, notification(paused, elapsed))
    }

    override fun onDestroy() {
        destroyed = true
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        const val ACTION_START = "cc.idomus.meetprotocol.capture.START"
        const val ACTION_PAUSE = "cc.idomus.meetprotocol.capture.PAUSE"
        const val ACTION_RESUME = "cc.idomus.meetprotocol.capture.RESUME"
        const val ACTION_STOP = "cc.idomus.meetprotocol.capture.STOP"
        const val EXTRA_MEETING_ID = "meeting_id"
        private const val CHANNEL = "meeting_recording"
        private const val NOTIFICATION_ID = 41
        private const val WAKE_TIMEOUT_MS = 60_000L

        /** Call on IO once at fresh process startup, before repository.recoverInterrupted(). */
        fun recoverAudio(repository: MeetingRepository) {
            repository.meetings().forEach { meeting -> recoverMeetingAudio(repository, meeting) }
        }

        private fun recoverMeetingAudio(repository: MeetingRepository, meeting: Meeting) {
            val directory = repository.meetingDirectory(meeting.id).canonicalFile
            val files = directory.listFiles() ?: return
            val registered = repository.segments(meeting.id).associateBy { it.index }
            var lastSample = 0L
            var damaged = false
            files
                .sortedBy { it.name }
                .forEach { file ->
                    val (index, startSamples) = WavWriter.parseName(file) ?: return@forEach
                    if (!file.isFile) return@forEach
                    try {
                        if (file.canonicalFile.parentFile != directory)
                            throw IOException("Audio outside meeting directory")
                        // Immutable finalized chunks already committed to SQLite need no rewrite or
                        // repeated insert. Recovery remains linear for a library of long meetings.
                        val existing = registered[index]
                        if (
                            !file.name.endsWith(".part") &&
                                existing != null &&
                                File(existing.audioPath).canonicalFile == file.canonicalFile
                        ) {
                            val count = (file.length() - WavWriter.HEADER_BYTES) / 2
                            val end = Math.addExact(startSamples, count)
                            if (
                                file.length() < WavWriter.HEADER_BYTES ||
                                    existing.startMs != milliseconds(startSamples) ||
                                    existing.endMs != milliseconds(end)
                            ) {
                                throw IOException("Audio chunk length changed")
                            }
                            lastSample = maxOf(lastSample, end)
                            return@forEach
                        }
                        val chunk = WavWriter.recover(file) ?: return@forEach
                        repository.addSegment(chunk.toSegment(meeting.id))
                        lastSample = maxOf(lastSample, chunk.endSamples)
                    } catch (_: IOException) {
                        damaged = true
                    } catch (_: IllegalArgumentException) {
                        damaged = true
                    }
                }
            if (lastSample > 0)
                repository.setCapture(
                    meeting.id,
                    meeting.capture,
                    maxOf(meeting.durationMs, milliseconds(lastSample)),
                )
            if (damaged)
                repository.setProcessing(
                    meeting.id,
                    ProcessState.ERROR,
                    "Один из фрагментов записи повреждён. Доступное аудио сохранено; повреждённый файл оставлен для восстановления.",
                )
        }

        private fun milliseconds(samples: Long) = samples * 1000 / WavWriter.SAMPLE_RATE

        private fun AudioChunk.toSegment(meetingId: String) =
            Segment(
                id =
                    UUID.nameUUIDFromBytes("$meetingId:$index".toByteArray(Charsets.UTF_8))
                        .toString(),
                meetingId = meetingId,
                index = index,
                startMs = milliseconds(startSamples),
                endMs = milliseconds(endSamples),
                audioPath = file.absolutePath,
            )
    }
}

private class CaptureSilencedException : IOException("Microphone silenced by Android")
