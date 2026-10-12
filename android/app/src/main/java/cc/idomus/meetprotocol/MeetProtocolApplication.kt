package cc.idomus.meetprotocol

import android.app.Application
import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class MeetProtocolApplication : Application() {
    val appGraph by lazy { AppGraph(this) }

    override fun onCreate() {
        super.onCreate()
        appGraph.initialize()
    }

    companion object {
        fun graph(context: Context): AppGraph =
            (context.applicationContext as MeetProtocolApplication).appGraph
    }
}

class AppGraph(context: Context) {
    val repository = MeetingRepository(context)
    val settings = SettingsStore(context)
    val queue = ProcessingQueue(context, repository, settings)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _ready = MutableStateFlow(false)
    val ready: StateFlow<Boolean> = _ready
    val startupError = MutableStateFlow("")

    fun initialize() {
        scope.launch {
            try {
                RecordingService.recoverAudio(repository)
                repository.recoverInterrupted()
                _ready.value = true
                queue.resumeAll()
            } catch (_: Exception) {
                startupError.value =
                    "Не удалось открыть библиотеку. Перезапустите приложение. Данные сохранены на телефоне."
            }
        }
    }
}
