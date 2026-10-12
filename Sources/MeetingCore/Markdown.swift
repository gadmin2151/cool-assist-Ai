import Foundation

public enum Markdown {
  public static func escaped(_ text: String) -> String {
    var result = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(
      of: "\n", with: " ")
    for token in ["\\", "`", "*", "_", "[", "]", "<", ">", "#", "|"] {
      result = result.replacingOccurrences(of: token, with: "\\" + token)
    }
    return result
  }
  public static func updatingTitle(_ document: String, meeting: Meeting) -> String {
    var lines = document.components(separatedBy: "\n")
    guard lines.first?.hasPrefix("# ") == true else { return document }
    lines[0] = "# \(escaped(meeting.title))"
    let end = lines.firstIndex(where: { $0.hasPrefix("## ") }) ?? lines.count
    if let index = lines[..<end].firstIndex(where: { $0.hasPrefix("- Проект: ") }) {
      lines.remove(at: index)
    }
    if let project = meeting.project {
      lines.insert("- Проект: \(escaped(project))", at: min(2, lines.count))
    }
    return lines.joined(separator: "\n")
  }
  public static func transcript(_ results: [Transcription]) -> String {
    let entries = results.flatMap { result in result.utterances.map { (result.chunk.source, $0) } }
      .sorted { $0.1.start < $1.1.start }
    return entries.map { source, utterance in
      "**[\(timestamp(utterance.start))–\(timestamp(utterance.end))] \(source.label):** \(escaped(utterance.text))"
    }.joined(separator: "\n\n")
  }
  public static func document(
    meeting: Meeting, results: [Transcription], notes: [TimelineNote], report: String? = nil,
    pendingCount: Int = 0
  ) -> String {
    var parts = [
      "# \(escaped(meeting.title))",
      "- Дата: \(meeting.startedAt.formatted(date: .long, time: .shortened))\n- Длительность: \(timestamp(meeting.duration))\n- Статус: \(meeting.status.label)\n- Распознавание речи: локально на Mac\n- Источники: микрофон и системный звук; имена говорящих автоматически не определяются.",
    ]
    if let project = meeting.project { parts.insert("- Проект: \(escaped(project))", at: 1) }
    if pendingCount > 0 {
      parts.append(
        "> Расшифровка неполная: ожидают обработки \(pendingCount) аудиофрагментов. Исходные записи сохранены."
      )
    }
    if !meeting.issues.isEmpty {
      parts.append(
        "## Замечания к записи\n\n"
          + meeting.issues.map { "- " + escaped($0) }.joined(separator: "\n"))
    }
    parts.append(
      "## Протокол и итоги\n\n> Редакторский черновик AI-модели. Проверяйте выводы, имена и формулировки по полной расшифровке ниже: автоматическая обработка может ошибаться.\n\n"
        + (report
          ?? "Структурированный протокол ещё не подготовлен. Полная доступная расшифровка приведена ниже.")
    )
    parts.append(
      "## Полная расшифровка\n\nТекст распознавания сохранён отдельно от редакторской обработки. Возможны ошибки имён, чисел и речи при одновременном разговоре.\n\n"
        + (results.flatMap(\.utterances).isEmpty ? "Речь пока не распознана." : transcript(results))
    )
    let semantic = notes.filter { $0.kind != "screen" }
    if !semantic.isEmpty {
      parts.append(
        "## Заметки по ходу встречи\n\n"
          + semantic.map {
            "### \(timestamp($0.time)) · \(escaped($0.kind))\n\n\(escaped($0.text))"
          }.joined(separator: "\n\n"))
    }
    let screen = notes.filter { $0.kind == "screen" }
    if !screen.isEmpty {
      parts.append(
        "## Текст на экране\n\nПериодическое OCR: это визуальный контекст, а не произнесённая речь.\n\n"
          + screen.map { "**[\(timestamp($0.time))]** \(escaped($0.text))" }.joined(
            separator: "\n\n"))
    }
    parts.append(
      "## Акустические пометки\n\nПриблизительные измерения сигнала, не достоверное определение эмоций или намерений.\n\n"
        + results.filter { !$0.utterances.isEmpty }.map {
          "- \(timestamp($0.chunk.start)) · \($0.chunk.source.label): \($0.chunk.features.note)."
        }.joined(separator: "\n"))
    return parts.joined(separator: "\n\n") + "\n"
  }

  /// Bounds every input, preserving every Unicode character, including a single oversized utterance.
  public static func batches(_ text: String, limit: Int = 6000) -> [String] {
    precondition(limit > 0)
    var batches: [String] = []
    var buffer = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var remaining = String(line) + "\n"
      while !remaining.isEmpty {
        let room = limit - buffer.count
        let piece = String(remaining.prefix(room))
        buffer += piece
        remaining.removeFirst(piece.count)
        if buffer.count == limit {
          batches.append(buffer)
          buffer = ""
        }
      }
    }
    if !buffer.isEmpty { batches.append(buffer) }
    return batches
  }
}
