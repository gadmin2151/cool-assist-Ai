package cc.idomus.meetprotocol

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Commands originate from the visible activity; only stop is also exposed in the notification. */
object CaptureController {
    private val mutableStatus = MutableStateFlow(CaptureStatus())
    val status: StateFlow<CaptureStatus> = mutableStatus.asStateFlow()

    fun start(context: Context, meetingId: String) {
        if (status.value.meetingId != null) return
        if (runCatching { UUID.fromString(meetingId).toString() }.getOrNull() != meetingId) {
            publish(CaptureStatus(warning = "Не удалось открыть встречу для записи."))
            return
        }
        // Check before creating an FGS. A rejected service cannot promote itself without
        // this permission, and merely stopping it can leave Android's start deadline armed.
        if (
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            publish(CaptureStatus(warning = "Для записи требуется разрешение на микрофон."))
            return
        }
        publish(CaptureStatus(meetingId = meetingId, warning = "Подготовка микрофона…"))
        try {
            context.startForegroundService(
                Intent(context, RecordingService::class.java)
                    .setAction(RecordingService.ACTION_START)
                    .putExtra(RecordingService.EXTRA_MEETING_ID, meetingId)
            )
        } catch (_: SecurityException) {
            publish(
                CaptureStatus(
                    warning = "Разрешите микрофон и начните запись из открытого приложения."
                )
            )
        } catch (_: IllegalStateException) {
            publish(CaptureStatus(warning = "Откройте приложение, чтобы начать запись."))
        }
    }

    fun pause(context: Context) = send(context, RecordingService.ACTION_PAUSE)

    fun resume(context: Context) = send(context, RecordingService.ACTION_RESUME)

    fun stop(context: Context) = send(context, RecordingService.ACTION_STOP)

    private fun send(context: Context, action: String) {
        if (status.value.meetingId == null) return
        try {
            context.startService(Intent(context, RecordingService::class.java).setAction(action))
        } catch (_: IllegalStateException) {
            publish(status.value.copy(warning = "Откройте приложение, чтобы управлять записью."))
        } catch (_: SecurityException) {
            publish(
                status.value.copy(
                    warning = "Android ограничил доступ к записи. Откройте приложение."
                )
            )
        }
    }

    internal fun publish(status: CaptureStatus) {
        mutableStatus.value = status
    }

    internal fun publishForMeeting(meetingId: String, status: CaptureStatus) {
        mutableStatus.update { current -> if (current.meetingId == meetingId) status else current }
    }
}
