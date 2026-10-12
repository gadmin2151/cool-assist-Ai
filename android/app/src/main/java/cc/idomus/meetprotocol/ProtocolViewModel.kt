package cc.idomus.meetprotocol

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class Workspace(
    val meetings: List<Meeting> = emptyList(),
    val selected: Meeting? = null,
    val segments: List<Segment> = emptyList(),
    val tasks: List<MeetingTask> = emptyList(),
    val settings: AppSettings = AppSettings(),
    val ready: Boolean = false,
)

class ProtocolViewModel(application: Application, private val saved: SavedStateHandle) :
    AndroidViewModel(application) {
    val graph = MeetProtocolApplication.graph(application)
    val selection = saved.getStateFlow<String?>("meeting", null)
    val page = saved.getStateFlow("page", "library")
    val busy = MutableStateFlow(false)
    val messages = MutableSharedFlow<String>(extraBufferCapacity = 8)
    private val settingsRevision = MutableStateFlow(0L)
    val workspace =
        combine(graph.repository.revision, selection, settingsRevision, graph.ready) {
                _,
                selectedId,
                _,
                ready ->
                if (!ready) Workspace()
                else
                    Workspace(
                        meetings = graph.repository.meetings(),
                        selected = selectedId?.let { graph.repository.meeting(it) },
                        segments = selectedId?.let { graph.repository.segments(it) } ?: emptyList(),
                        tasks = graph.repository.tasks(),
                        settings = graph.settings.read(),
                        ready = true,
                    )
            }
            .flowOn(Dispatchers.IO)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), Workspace())

    fun select(id: String?) {
        saved["meeting"] = id
        saved["page"] = "library"
    }

    fun navigate(value: String) {
        saved["page"] = value
        if (value == "library") saved["meeting"] = null
    }

    fun message(text: String) {
        messages.tryEmit(text)
    }

    fun refreshSettings() {
        settingsRevision.value++
    }

    fun createAndRecord(context: Context, title: String) {
        if (busy.value || CaptureController.status.value.meetingId != null) return
        busy.value = true
        viewModelScope.launch {
            try {
                val meeting =
                    withContext(Dispatchers.IO) {
                        graph.repository.createMeeting(
                            title.trim().ifBlank { "Новая встреча" },
                            graph.settings.read(),
                        )
                    }
                select(meeting.id)
                CaptureController.start(context, meeting.id)
            } catch (_: Exception) {
                message("Не удалось начать запись. Проверьте доступ к микрофону и свободное место.")
            } finally {
                busy.value = false
            }
        }
    }

    fun rename(id: String, title: String) = mutate {
        graph.repository.rename(id, title.trim().take(200))
    }

    fun notes(id: String, text: String) = mutate {
        graph.repository.saveNotes(id, text)
        message("Заметки сохранены")
    }

    fun delete(id: String) = mutate {
        check(CaptureController.status.value.meetingId != id)
        graph.queue.cancel(id)
        graph.repository.deleteMeeting(id)
        withContext(Dispatchers.Main) { if (selection.value == id) select(null) }
    }

    fun bookmark(id: String, elapsedMs: Long) = mutate {
        val meeting = graph.repository.meeting(id) ?: return@mutate
        val mark = "[${clockText(elapsedMs)}] Важный момент"
        val updated = (meeting.notes + "\n" + mark).trim()
        if (updated.length > 50_000) {
            message("В заметках нет места для новой отметки. Сократите текст заметок.")
            return@mutate
        }
        graph.repository.saveNotes(id, updated)
        message("Момент добавлен в заметки")
    }

    fun cancelProcessing(id: String) = mutate { graph.queue.cancel(id) }

    fun retry(id: String) = mutate { graph.queue.retry(id) }

    fun summary(id: String) = mutate {
        graph.queue.requestSummary(id, graph.settings.read().summaryModel)
    }

    fun addTask(id: String, text: String, owner: String = "", due: String = "") = mutate {
        graph.repository.addTask(id, text.trim(), owner.trim(), due.trim())
        message("Задача добавлена")
    }

    fun toggleTask(task: MeetingTask) = mutate { graph.repository.toggleTask(task.id, !task.done) }

    fun deleteTask(id: String) = mutate { graph.repository.deleteTask(id) }

    suspend fun markdown(id: String): String =
        withContext(Dispatchers.IO) {
            val meeting = graph.repository.meeting(id) ?: error("Встреча удалена")
            exportMarkdown(
                meeting,
                graph.repository.segments(id),
                graph.repository.tasks().filter { it.meetingId == id },
            )
        }

    private fun mutate(action: suspend () -> Unit) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                action()
            } catch (_: Exception) {
                message("Не удалось сохранить изменение. Попробуйте ещё раз.")
            }
        }
    }
}
