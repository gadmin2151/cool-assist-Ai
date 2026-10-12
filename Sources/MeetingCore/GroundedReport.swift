import Foundation

/// The small model selects source IDs; it cannot invent action owners, dates or quotations.
/// Every spoken passage is rendered even when the model omits it from its topic index.
enum GroundedReport {
  struct Entry: Encodable {
    let id: Int
    let time: String
    let source: String
    let text: String
    let acousticContext: String
    let start: Double
  }
  struct Topic: Decodable {
    let title: String
    let ids: [Int]
  }
  struct Index: Decodable {
    let summary: [Int]
    let decisions: [Int]
    let actions: [Int]
    let questions: [Int]
    let topics: [Topic]
  }
  struct Selection: Decodable { let ids: [Int] }

  private static let indexSchema = """
    {"type":"object","properties":{
      "summary":{"type":"array","items":{"type":"integer"},"minItems":1,"maxItems":4},
      "decisions":{"type":"array","items":{"type":"integer"},"maxItems":40},
      "actions":{"type":"array","items":{"type":"integer"},"maxItems":40},
      "questions":{"type":"array","items":{"type":"integer"},"maxItems":40},
      "topics":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"object","properties":{
        "title":{"type":"string","maxLength":80},
        "ids":{"type":"array","items":{"type":"integer"},"maxItems":100}},
        "required":["title","ids"],"additionalProperties":false}}},
      "required":["summary","decisions","actions","questions","topics"],"additionalProperties":false}
    """
  private static let selectionSchema = """
    {"type":"object","properties":{"ids":{"type":"array","items":{"type":"integer"},"maxItems":8}},"required":["ids"],"additionalProperties":false}
    """

  static func build(
    ai: LocalAI, results: [Transcription], notes: [TimelineNote], directory: URL,
    progress: @Sendable (String) async -> Void
  ) async throws -> MeetingReport {
    var entries: [Entry] = []
    let utterances = results.flatMap { result in result.utterances.map { (result.chunk, $0) } }
      .sorted { $0.1.start < $1.1.start }
    for (chunk, utterance) in utterances {
      for piece in Markdown.batches(utterance.text, limit: 3000) {
        entries.append(
          Entry(
            id: entries.count + 1, time: timestamp(utterance.start),
            source: chunk.source.label, text: piece.trimmingCharacters(in: .whitespacesAndNewlines),
            acousticContext: chunk.features.note, start: utterance.start))
      }
    }
    let batches = partition(entries)
    var summaryIDs: [Int] = []
    var decisionIDs: [Int] = []
    var actionIDs: [Int] = []
    var questionIDs: [Int] = []
    var topics: [Topic] = []
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for (number, batch) in batches.enumerated() {
      try Task.checkCancellation()
      await progress(
        batches.count == 1
          ? "Группирую реплики и итоги"
          : "Темы и итоги: часть \(number + 1) из \(batches.count)")
      let source = String(decoding: try encoder.encode(batch), as: UTF8.self)
      let allowedIDs = batch.map { String($0.id) }.joined(separator: ",")
      let schema = indexSchema.replacingOccurrences(
        of: "\"type\":\"integer\"",
        with: "\"type\":\"integer\",\"enum\":[\(allowedIDs)]")
      let from = batch.first?.start ?? 0
      let to = batch.last?.start ?? from
      let context = notes.filter { $0.time >= from - 20 && $0.time <= to + 20 }
        .map { "\($0.kind) (контекст, не речь): \($0.text)" }.joined(separator: "\n")
      let raw = try await ai.generate(
        instruction:
          "Classify the Russian transcript by numeric id. summary: select 1 to 4 important statements. decisions: statements saying a decision was made (e.g. решили). actions: statements explicitly promising or assigning work (e.g. подготовит). An objection does NOT assign work to its speaker. questions: unresolved issues (e.g. пока не утвержден). topics: group ALL ids into topics with short Russian titles. Return the id values from the input, NOT array positions or timestamps. Empty decisions/actions/questions are allowed only when no such statements exist. Never put a mere proposal or objection under decisions. Ignore acoustic measurements as facts; screen context is not speech.",
        input: source + "\nКонтекст (полностью сохранён отдельно в Markdown):\n"
          + String(context.prefix(1200)),
        directory: directory, tokens: 1200, schema: schema)
      let index = try JSONDecoder().decode(Index.self, from: Data(raw.utf8))
      try SessionStore.writePrivate(
        Data(raw.utf8),
        to: directory.appendingPathComponent(String(format: "index-%04d.json", number)))
      let valid = Set(batch.map(\.id))
      summaryIDs += unique(index.summary, allowed: valid)
      decisionIDs += unique(index.decisions, allowed: valid)
      actionIDs += unique(index.actions, allowed: valid)
      questionIDs += unique(index.questions, allowed: valid)
      topics += index.topics.map { Topic(title: $0.title, ids: unique($0.ids, allowed: valid)) }
    }
    let allIDs = Set(entries.map(\.id))
    summaryIDs = unique(summaryIDs, allowed: allIDs)
    // Bound summary input without discarding the separately accumulated actions and decisions.
    for _ in 0..<12 where summaryIDs.count > 8 {
      await progress("Выбираю основные тезисы встречи")
      let candidates = entries.filter { summaryIDs.contains($0.id) }
      var reduced: [Int] = []
      for batch in partition(candidates) {
        let raw = try await ai.generate(
          instruction:
            "Выбери до 8 id основных тезисов из этой группы. Сохрани важные решения и изменения позиции, учитывай конец встречи. Верни только существующие числовые id.",
          input: String(decoding: try encoder.encode(batch), as: UTF8.self), directory: directory,
          tokens: 200, schema: selectionSchema)
        let selection = try JSONDecoder().decode(Selection.self, from: Data(raw.utf8))
        let selected = unique(selection.ids, allowed: Set(batch.map(\.id)))
        reduced += selected.isEmpty ? batch.map(\.id) : selected
      }
      reduced = unique(reduced, allowed: allIDs)
      guard reduced.count < summaryIDs.count else { break }
      summaryIDs = reduced
    }
    let lookup = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    func lines(_ ids: [Int]) -> String {
      let valid = unique(ids, allowed: allIDs).sorted()
      guard !valid.isEmpty else { return "Явно не выделены в записи." }
      return valid.compactMap { lookup[$0] }.map {
        "- **[\($0.time)] \($0.source):** \(Markdown.escaped($0.text))"
      }.joined(separator: "\n")
    }
    var parts = [
      "Ключевые пункты приведены исходными репликами: модель выбирает и группирует их, не дописывая исполнителей или сроки. Классификация может ошибаться.",
      "### Краткое содержание\n\n" + lines(summaryIDs),
      "### Решения\n\n" + lines(decisionIDs),
      "### Поручения\n\n" + lines(actionIDs),
      "### Открытые вопросы\n\n" + lines(questionIDs),
      "### Обсуждение по темам",
    ]
    var rendered = Set<Int>()
    for topic in topics {
      let ids = unique(topic.ids, allowed: allIDs).filter { !rendered.contains($0) }.sorted()
      guard !ids.isEmpty else { continue }
      rendered.formUnion(ids)
      parts.append("#### \(Markdown.escaped(topic.title))\n\n" + lines(ids))
    }
    let remaining = entries.map(\.id).filter { !rendered.contains($0) }
    if !remaining.isEmpty { parts.append("#### Остальные реплики\n\n" + lines(remaining)) }
    func excerpts(_ ids: [Int]) -> [SourceExcerpt] {
      unique(ids, allowed: allIDs).sorted().compactMap { lookup[$0] }.map {
        SourceExcerpt(
          start: $0.start,
          source: $0.source == AudioSource.microphone.label ? .microphone : .system, text: $0.text)
      }
    }
    var insights = MeetingInsights()
    insights.summary = excerpts(summaryIDs)
    insights.decisions = excerpts(decisionIDs)
    insights.actions = excerpts(actionIDs)
    insights.questions = excerpts(questionIDs)
    insights.topics = topics.map { ReportTopic(title: $0.title, excerpts: excerpts($0.ids)) }
    if !remaining.isEmpty {
      insights.topics.append(ReportTopic(title: "Остальные реплики", excerpts: excerpts(remaining)))
    }
    return MeetingReport(markdown: parts.joined(separator: "\n\n"), insights: insights)
  }

  private static func unique(_ ids: [Int], allowed: Set<Int>) -> [Int] {
    var seen = Set<Int>()
    return ids.filter { allowed.contains($0) && seen.insert($0).inserted }
  }
  private static func partition(_ entries: [Entry]) -> [[Entry]] {
    var batches: [[Entry]] = []
    var current: [Entry] = []
    var count = 0
    for entry in entries {
      let size = entry.text.count + entry.acousticContext.count + 180
      if !current.isEmpty && count + size > 4000 {
        batches.append(current)
        current = []
        count = 0
      }
      current.append(entry)
      count += size
    }
    if !current.isEmpty { batches.append(current) }
    return batches
  }
}
