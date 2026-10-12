package cc.idomus.meetprotocol

enum class CaptureState {
    RECORDING,
    PAUSED,
    STOPPED,
    INTERRUPTED,
}

enum class ProcessState {
    IDLE,
    TRANSCRIBING,
    SUMMARIZING,
    COMPLETE,
    ERROR,
}

enum class SegmentState {
    PENDING,
    DONE,
}

data class Meeting(
    val id: String,
    val title: String,
    val createdAt: Long,
    val durationMs: Long = 0,
    val capture: CaptureState = CaptureState.STOPPED,
    val processing: ProcessState = ProcessState.IDLE,
    val error: String = "",
    val summary: Brief? = null,
    val summaryModel: String = "gpt-5.4",
    val transcriptionModel: String = "gpt-4o-transcribe",
    val notes: String = "",
    val summaryRequested: Boolean = false,
    val generatedSummaryModel: String? = null,
)

data class Segment(
    val id: String,
    val meetingId: String,
    val index: Int,
    val startMs: Long,
    val endMs: Long,
    val audioPath: String,
    val text: String = "",
    val state: SegmentState = SegmentState.PENDING,
)

data class BriefPoint(val topic: String, val text: String, val sources: List<Int> = emptyList())

data class ActionProposal(
    val text: String,
    val owner: String,
    val due: String,
    val sources: List<Int> = emptyList(),
)

data class Brief(
    val introduction: String,
    val points: List<BriefPoint>,
    val decisions: List<String>,
    val actions: List<ActionProposal>,
    val questions: List<String>,
)

data class MeetingTask(
    val id: String,
    val meetingId: String,
    val text: String,
    val owner: String = "",
    val due: String = "",
    val done: Boolean = false,
)

data class AppSettings(
    val summaryModel: String = "gpt-5.4",
    val transcriptionModel: String = "gpt-4o-transcribe",
    val language: String = "ru",
    val hasKey: Boolean = false,
)

data class CaptureStatus(
    val meetingId: String? = null,
    val paused: Boolean = false,
    val elapsedMs: Long = 0,
    val level: Float = 0f,
    val warning: String = "",
)

fun clockText(milliseconds: Long): String {
    val total = milliseconds.coerceAtLeast(0) / 1000
    return if (total >= 3600) "%d:%02d:%02d".format(total / 3600, total / 60 % 60, total % 60)
    else "%02d:%02d".format(total / 60, total % 60)
}
