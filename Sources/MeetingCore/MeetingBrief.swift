import Foundation

public struct BriefPoint: Codable, Sendable {
  public let topic: String
  public let text: String
  public let sources: [SourceExcerpt]
  /// Preserve a named assignee without guessing whether the topic is a person's name.
  public var taskTitle: String { "\(topic): \(text)" }
  public init(topic: String, text: String, sources: [SourceExcerpt]) {
    self.topic = topic
    self.text = text
    self.sources = sources
  }
}

/// An editorial résumé, kept separate from the verbatim evidence and editable tasks.
public struct MeetingBrief: Codable, Sendable {
  public let introduction: String
  public let points: [BriefPoint]
  public let nextSteps: [BriefPoint]
  public var generation: BriefGeneration?
  public init(
    introduction: String, points: [BriefPoint], nextSteps: [BriefPoint],
    generation: BriefGeneration? = nil
  ) {
    self.introduction = introduction
    self.points = points
    self.nextSteps = nextSteps
    self.generation = generation
  }

  public func heading(for meeting: Meeting) -> String {
    let date = DateFormatter()
    date.locale = Locale(identifier: "ru_RU")
    date.dateFormat = "d MMMM yyyy"
    let name = [meeting.title, meeting.project].compactMap { $0 }.joined(separator: " / ")
    return "Резюме встречи \(name) — \(date.string(from: meeting.startedAt))"
  }

  public func markdown(for meeting: Meeting, includeSources: Bool = false) -> String {
    func line(_ point: BriefPoint) -> String {
      let text = "- **\(Markdown.escaped(point.topic)):** \(Markdown.escaped(point.text))"
      guard includeSources else { return text }
      return text + " _[\(point.sources.map { timestamp($0.start) }.joined(separator: ", "))]_"
    }
    var sections = [
      "## \(Markdown.escaped(heading(for: meeting)))",
      Markdown.escaped(introduction),
      points.map(line).joined(separator: "\n"),
    ]
    if !nextSteps.isEmpty {
      sections.append("**Ближайшие действия:**\n\n" + nextSteps.map(line).joined(separator: "\n"))
    }
    if includeSources, let generation {
      sections.append("_Резюме: \(Markdown.escaped(generation.configuration.label))_")
    }
    return sections.joined(separator: "\n\n")
  }
}

extension Markdown {
  /// Updates the owned résumé block and processing label; original speech and report stay intact.
  public static func replacingBrief(
    in document: String, with brief: MeetingBrief, meeting: Meeting
  ) -> String {
    var document = document
    if let firstSection = document.range(of: "## ") {
      let header = String(document[..<firstSection.lowerBound]).replacingOccurrences(
        of: "- Обработка: локально на Mac", with: "- Распознавание речи: локально на Mac")
      document = header + document[firstSection.lowerBound...]
    }
    let start = "<!-- meet-protocol:brief:start -->"
    let end = "<!-- meet-protocol:brief:end -->"
    let section = start + "\n" + brief.markdown(for: meeting, includeSources: true) + "\n" + end
    if let lower = document.range(of: start),
      let upper = document.range(of: end, range: lower.upperBound..<document.endIndex)
    {
      return document.replacingCharacters(in: lower.lowerBound..<upper.upperBound, with: section)
    }
    let position = document.range(of: "## Протокол и итоги")?.lowerBound ?? document.endIndex
    var value = document
    value.insert(contentsOf: section + "\n\n", at: position)
    return value
  }
}

extension LocalAI {
  public func prepareBrief(
    results: [Transcription], meeting: Meeting, directory: URL,
    progress: @Sendable (String) async -> Void
  ) async throws -> MeetingBrief {
    try await BriefBuilder.build(
      results: results, meeting: meeting, configuration: SummaryConfiguration(),
      inputLimit: 6000, progress: progress
    ) { instruction, input, schema in
      try await generate(
        instruction: instruction, input: input, directory: directory,
        tokens: 3000, schema: schema, context: 16384, editorial: true)
    }
  }
}

package enum BriefBuilder {
  package struct Block {
    package let id: Int
    package let source: SourceExcerpt
    package let text: String
  }
  struct Point: Codable {
    let topic: String
    let text: String
    let ids: [Int]
  }
  struct Draft: Codable {
    let introduction: String
    let points: [Point]
    let nextSteps: [Point]
  }
  // Every ID refers to exactly the text shown to the model, with its original channel
  // and time. Combining speakers under one anchor loses evidence for later sentences.
  // Echo suppression affects AI input only; the original transcript remains intact.
  package static func blocks(_ results: [Transcription]) -> [Block] {
    let speech = results.flatMap { result in
      result.utterances.map {
        (
          source: SourceExcerpt(start: $0.start, source: result.chunk.source, text: $0.text),
          end: $0.end
        )
      }
    }.sorted {
      if $0.source.start != $1.source.start { return $0.source.start < $1.source.start }
      return $0.source.source.rawValue < $1.source.source.rawValue
    }
    var blocks: [Block] = []
    var recent: [(start: Double, end: Double, channel: AudioSource, key: String)] = []
    for item in speech {
      let source = item.source
      let text = source.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      recent.removeAll { source.start - $0.end > 1 }
      let words = text.lowercased().split(whereSeparator: \.isWhitespace)
      let key = words.joined(separator: " ")
      // Short acknowledgements can be separate speakers agreeing, not loopback echo.
      if words.count >= 5,
        recent.contains(where: {
          $0.channel != source.source && abs(source.start - $0.start) <= 2 && $0.key == key
        })
      {
        continue
      }
      recent.append((source.start, item.end, source.source, key))
      for piece in Markdown.batches(text, limit: 1200) {
        let excerpt = SourceExcerpt(
          start: source.start, source: source.source,
          text: piece.trimmingCharacters(in: .whitespacesAndNewlines))
        blocks.append(Block(id: blocks.count + 1, source: excerpt, text: excerpt.text))
      }
    }
    return blocks
  }

  private static let instruction = """
    Приведи разговор в порядок и сделай деловое резюме для человека, который не присутствовал на встрече.
    introduction: одно короткое предложение о предмете встречи. points: 4–10 содержательных пунктов по темам (меньше, если встреча короткая), у каждого короткий topic и связный text из 1–2 предложений. Общий объём всего резюме — около 250–400 слов. Объединяй повторные обсуждения одной темы, пиши итоговую позицию с учётом конца разговора. Убирай междометия, повторы, обрывки распознавания и бытовые отступления. Это пересказ смысла, а не подборка цитат и не хронология реплик. Избегай пустых фраз «обсудили детали», «уточнили вопросы» — называй конкретный результат.
    nextSteps: только явно порученные, обещанные или запрошенные ближайшие действия, 0–6 пунктов. topic — исполнитель, если он назван, иначе краткое название действия; text — что сделать и срок, только если он прозвучал. Нерешённый вопрос сам по себе НЕ поручение. Фразы «цены ещё нужно уточнить» или «срок неизвестен» без явного поручения, обещания либо просьбы описывают открытый вопрос: оставь их в points, не в nextSteps. Не превращай необходимость, ожидание или рекомендацию в назначенную задачу. Не пиши «не указано» для отсутствующих исполнителей и сроков, просто опусти их.
    Различай принятое решение, предложение, запрос и запасной вариант. Условные действия и запасные варианты должны остаться условными. Приблизительная дата — ориентир, а не обещание. Не распространяй условия одного предложения на всю работу. Исправляй очевидные речевые ошибки, но не угадывай неразборчивые модели, цены и фамилии. Если источники противоречат друг другу, укажи, что деталь требует уточнения. Сохраняй существенные числа, отрицания и исключения. Не добавляй причины и договорённости, которых не было. Название встречи — контекст, а не дополнительные факты.
    Для каждого пункта верни ids фрагментов, которые подтверждают его содержание, обычно 1–4. У каждого пункта должны быть источники. Идентификаторы — только из входных данных. Обычный текст, без Markdown-разметки внутри полей. /no_think
    """

  private static let schema = """
    {"type":"object","properties":{
      "introduction":{"type":"string","minLength":1,"maxLength":500},
      "points":{"type":"array","minItems":1,"maxItems":12,"items":{"$ref":"#/$defs/point"}},
      "nextSteps":{"type":"array","maxItems":6,"items":{"$ref":"#/$defs/point"}}},
      "required":["introduction","points","nextSteps"],"additionalProperties":false,
      "$defs":{"point":{"type":"object","properties":{
        "topic":{"type":"string","minLength":1,"maxLength":100},
        "text":{"type":"string","minLength":1,"maxLength":700},
        "ids":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"integer"}}},
        "required":["topic","text","ids"],"additionalProperties":false}}}
    """

  static func build(
    results: [Transcription], meeting: Meeting, configuration: SummaryConfiguration,
    inputLimit: Int, progress: @Sendable (String) async -> Void,
    generate: @Sendable (String, String, String) async throws -> String
  ) async throws -> MeetingBrief {
    let blocks = blocks(results)
    guard !blocks.isEmpty else {
      throw MeetingError.message("Для резюме пока нет распознанной речи.")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let heading =
      "Название: \(meeting.title.prefix(300))\nПроект: \((meeting.project ?? "").prefix(300))\n"
    let contentLimit = inputLimit - heading.count
    guard contentLimit >= 2000 else {
      throw MeetingError.message("Недостаточный размер контекста для резюме.")
    }
    var inputs = partition(
      blocks.map {
        (
          "[\($0.id) · \(timestamp($0.source.start)) · \($0.source.source.label)] \($0.text)",
          Set([$0.id])
        )
      }, limit: contentLimit)
    var level = 0
    while true {
      var drafts: [Draft] = []
      for (index, input) in inputs.enumerated() {
        try Task.checkCancellation()
        await progress(
          inputs.count == 1
            ? "Составляю связное резюме" : "Резюме: часть \(index + 1) из \(inputs.count)")
        let intermediate =
          inputs.count > 1
          ? "Это часть длинной встречи. Сохрани все значимые темы этой части и конкретные детали для последующего объединения."
          : "Это все материалы встречи. Подготовь единое компактное резюме, исключи дубли тем."
        var accepted: Draft?
        for attempt in 0..<2 {
          let correction =
            attempt == 0
            ? ""
            : "\nПредыдущая попытка не прошла проверку. Напиши заново: короткие завершённые предложения без повторов; ids строго из источника."
          let raw = try await generate(
            instruction + "\n" + intermediate + correction,
            heading + input.0, schema)
          do {
            let draft = try JSONDecoder().decode(Draft.self, from: Data(raw.utf8))
            try validate(draft, allowed: input.1)
            accepted = draft
            break
          } catch {
            if attempt == 1 { throw error }
            await progress("Проверяю формулировки резюме")
          }
        }
        guard let accepted else { throw MeetingError.message("Резюме не сформировано.") }
        drafts.append(accepted)
      }
      if drafts.count == 1 {
        let lookup = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0.source) })
        func points(_ values: [Point]) -> [BriefPoint] {
          values.map { point in
            BriefPoint(
              topic: point.topic, text: point.text,
              sources: Set(point.ids).sorted().compactMap { lookup[$0] })
          }
        }
        return MeetingBrief(
          introduction: drafts[0].introduction,
          points: points(drafts[0].points), nextSteps: points(drafts[0].nextSteps),
          generation: BriefGeneration(configuration: configuration))
      }
      level += 1
      // A full draft may itself exceed the local model's input budget. Reduce by
      // source-linked points, never by slicing serialized JSON or enlarging context.
      struct ReductionPoint: Encodable {
        let kind: String
        let point: Point
      }
      let records = try drafts.flatMap { draft in
        try [("topic", draft.points), ("nextStep", draft.nextSteps)].flatMap { kind, points in
          try points.map { point in
            (
              String(
                decoding: try encoder.encode(ReductionPoint(kind: kind, point: point)),
                as: UTF8.self), Set(point.ids)
            )
          }
        }
      }
      let reduced = partition(records, limit: contentLimit)
      guard reduced.count < inputs.count, level < 8 else {
        throw MeetingError.message(
          "Не удалось сократить материалы до единого резюме. Расшифровка сохранена; повторите обработку."
        )
      }
      inputs = reduced
    }
  }

  static func validate(_ draft: Draft, allowed: Set<Int>) throws {
    func nonempty(_ value: String, limit: Int) -> Bool {
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= limit
    }
    func repeated(_ text: String) -> Bool {
      var seen = Set<String>()
      for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?;")) {
        let words = sentence.lowercased().split(whereSeparator: \.isWhitespace)
        if words.count >= 6, !seen.insert(words.joined(separator: " ")).inserted { return true }
      }
      return false
    }
    guard nonempty(draft.introduction, limit: 500), !draft.points.isEmpty,
      draft.points.count <= 12, draft.nextSteps.count <= 6,
      (draft.points + draft.nextSteps).allSatisfy({
        nonempty($0.topic, limit: 100) && nonempty($0.text, limit: 700) && !repeated($0.text)
          && !$0.ids.isEmpty && $0.ids.count <= 8 && Set($0.ids).isSubset(of: allowed)
      })
    else {
      throw MeetingError.message(
        "AI вернул неполное резюме или неверные ссылки на речь. Предыдущий результат сохранён.")
    }
  }

  static func partition(_ items: [(String, Set<Int>)], limit: Int = 18000) -> [(String, Set<Int>)] {
    var output: [(String, Set<Int>)] = []
    var text = ""
    var ids = Set<Int>()
    for item in items {
      if !text.isEmpty && text.count + item.0.count + 2 > limit {
        output.append((text, ids))
        text = ""
        ids = []
      }
      text += (text.isEmpty ? "" : "\n\n") + item.0
      ids.formUnion(item.1)
    }
    if !text.isEmpty { output.append((text, ids)) }
    return output
  }
}
