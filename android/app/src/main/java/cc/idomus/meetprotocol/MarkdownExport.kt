package cc.idomus.meetprotocol

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** The export is constructed from stored source text, never a shortened model response. */
fun exportMarkdown(meeting: Meeting, segments: List<Segment>, tasks: List<MeetingTask>): String =
    buildString {
        val ordered =
            segments
                .filter { it.meetingId == meeting.id }
                .sortedWith(compareBy({ it.startMs }, { it.index }))
        fun sources(indexes: List<Int>): String =
            indexes
                .mapNotNull { index ->
                    ordered
                        .firstOrNull { it.index == index }
                        ?.let { "[${clockText(it.startMs)}](#fragment-$index)" }
                }
                .joinToString(", ")
                .let { if (it.isEmpty()) "" else " · $it" }
        appendLine("# ${markdownText(meeting.title)}")
        appendLine()
        val date =
            DateTimeFormatter.ofPattern("d MMMM yyyy, HH:mm", Locale.forLanguageTag("ru"))
                .withZone(ZoneId.systemDefault())
                .format(Instant.ofEpochMilli(meeting.createdAt))
        appendLine("$date · ${clockText(meeting.durationMs)}")
        appendLine()
        if (meeting.capture == CaptureState.RECORDING || meeting.capture == CaptureState.PAUSED) {
            appendLine(
                "> Запись ещё продолжается. Экспорт содержит материалы, сохранённые к этому моменту."
            )
            appendLine()
        } else if (meeting.capture == CaptureState.INTERRUPTED) {
            appendLine(
                "> Запись прервалась. Ниже сохранённые материалы; конец встречи мог не попасть в запись."
            )
            appendLine()
        }
        val pending = ordered.count { it.state == SegmentState.PENDING }
        if (pending > 0 || meeting.summaryRequested || meeting.processing == ProcessState.ERROR) {
            appendLine(
                "> Обработка не завершена. Нераспознанных аудиофрагментов: $pending. ${if (meeting.summary != null) "Показано последнее сохранённое резюме." else "Итоговое резюме ещё не подготовлено."}"
            )
            appendLine()
        }
        meeting.summary?.let { brief ->
            appendLine("## Резюме встречи")
            appendLine()
            appendLine(markdownText(brief.introduction))
            appendLine()
            brief.points.forEach { point ->
                appendLine(
                    "- **${markdownText(point.topic)}:** ${markdownText(point.text)}${sources(point.sources)}"
                )
            }
            appendLine()
            if (brief.decisions.isNotEmpty()) {
                appendLine("### Решения")
                appendLine()
                brief.decisions.forEach { appendLine("- ${markdownText(it)}") }
                appendLine()
            }
            if (brief.actions.isNotEmpty()) {
                appendLine("### Ближайшие действия")
                appendLine()
                brief.actions.forEach { action ->
                    val details =
                        listOf(
                                action.owner.takeIf { it.isNotBlank() }?.let { "Исполнитель: $it" },
                                action.due.takeIf { it.isNotBlank() }?.let { "Срок: $it" },
                            )
                            .filterNotNull()
                            .joinToString("; ")
                    appendLine(
                        "- ${markdownText(action.text)}${if (details.isNotEmpty()) " (${markdownText(details)})" else ""}${sources(action.sources)}"
                    )
                }
                appendLine()
            }
            if (brief.questions.isNotEmpty()) {
                appendLine("### Открытые вопросы")
                appendLine()
                brief.questions.forEach { appendLine("- ${markdownText(it)}") }
                appendLine()
            }
            appendLine(
                "*Резюме подготовлено AI. Формулировки можно сверить с полной расшифровкой ниже.*"
            )
            appendLine()
        }
        val ownTasks = tasks.filter { it.meetingId == meeting.id }
        if (ownTasks.isNotEmpty()) {
            appendLine("## Задачи")
            appendLine()
            ownTasks.forEach { task ->
                val details =
                    listOf(task.owner, task.due).filter { it.isNotBlank() }.joinToString(" · ")
                appendLine(
                    "- [${if (task.done) "x" else " "}] ${markdownText(task.text)}${if (details.isNotEmpty()) " — ${markdownText(details)}" else ""}"
                )
            }
            appendLine()
        }
        if (meeting.notes.isNotBlank()) {
            appendLine("## Личные заметки")
            appendLine()
            appendLine(markdownText(meeting.notes))
            appendLine()
        }
        appendLine("## Полная расшифровка")
        appendLine()
        if (ordered.isEmpty()) appendLine("Аудиофрагменты пока не сохранены.")
        ordered.forEach { segment ->
            appendLine("<a id=\"fragment-${segment.index}\"></a>")
            appendLine("### ${clockText(segment.startMs)} — ${clockText(segment.endMs)}")
            appendLine()
            when {
                segment.state == SegmentState.PENDING ->
                    appendLine("[Аудио сохранено; этот фрагмент ещё не распознан.]")
                segment.text.isBlank() -> appendLine("[Речь в этом фрагменте не распознана.]")
                else -> appendLine(markdownText(segment.text))
            }
            appendLine()
        }
    }

/** Plain meeting text cannot inject HTML, images or executable links into exported Markdown. */
internal fun markdownText(value: String): String = buildString {
    for (character in value) when {
        character == '\n' || character == '\t' -> append(character)
        character == '\r' -> Unit
        character.code < 32 || character.code == 127 -> append(' ')
        character == '<' -> append("&lt;")
        character == '>' -> append("&gt;")
        character == '&' -> append("&amp;")
        character in "\\`*_{}[]()#+-.!|" -> {
            append('\\')
            append(character)
        }
        else -> append(character)
    }
}
