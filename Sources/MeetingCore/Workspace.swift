import CryptoKit
import Foundation

public struct SourceExcerpt: Codable, Identifiable, Equatable, Sendable {
  public var id: String {
    let value =
      "\(source.rawValue)|\(Int(max(0, min(Double(Int.max / 2), start.isFinite ? start : 0))))|\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public let start: Double
  public let source: AudioSource
  public let text: String
  public init(start: Double, source: AudioSource, text: String) {
    self.start = start.isFinite ? max(0, start) : 0
    self.source = source
    self.text = text
  }
}

public struct ReportTopic: Codable, Identifiable, Sendable {
  public var id: String { title + (excerpts.first?.id ?? "") }
  public let title: String
  public let excerpts: [SourceExcerpt]
  public init(title: String, excerpts: [SourceExcerpt]) {
    self.title = title
    self.excerpts = excerpts
  }
}

public struct MeetingInsights: Codable, Sendable {
  public var brief: MeetingBrief?
  public var summary: [SourceExcerpt] = []
  public var decisions: [SourceExcerpt] = []
  public var actions: [SourceExcerpt] = []
  public var questions: [SourceExcerpt] = []
  public var topics: [ReportTopic] = []
  public init() {}

  /// Reads the source-linked sections written by 1.0.x without rerunning the model.
  public static func legacy(markdown: String) -> Self {
    var value = Self()
    var section = ""
    let expression = try! NSRegularExpression(
      pattern: #"^- \*\*\[(\d+):(\d{2}):(\d{2})\] (Микрофон|Звук встречи):\*\* (.+)$"#)
    for line in markdown.components(separatedBy: .newlines) {
      if line.hasPrefix("##") {
        section = line
        continue
      }
      let range = NSRange(line.startIndex..., in: line)
      guard let match = expression.firstMatch(in: line, range: range) else { continue }
      func group(_ index: Int) -> String {
        Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
      }
      let hours = Double(group(1)) ?? 0
      let minutes = Double(group(2)) ?? 0
      let seconds = hours * 3600 + minutes * 60 + (Double(group(3)) ?? 0)
      var text = group(5)
      for character in ["\\", "*", "_", "[", "]", "#", "`", "<", ">", "|"] {
        text = text.replacingOccurrences(of: "\\" + character, with: character)
      }
      let excerpt = SourceExcerpt(
        start: seconds, source: group(4) == "Микрофон" ? .microphone : .system, text: text)
      switch section {
      case "### Краткое содержание": value.summary.append(excerpt)
      case "### Решения": value.decisions.append(excerpt)
      case "### Поручения": value.actions.append(excerpt)
      case "### Открытые вопросы": value.questions.append(excerpt)
      default: break
      }
    }
    return value
  }
}

public struct MeetingReport: Sendable {
  public var markdown: String
  public var insights: MeetingInsights
}

public struct SavedProtocol: Codable, Sendable {
  public let document: String
  public let insights: MeetingInsights
  public let generatedAt: Date
  public init(document: String, insights: MeetingInsights, generatedAt: Date = Date()) {
    self.document = document
    self.insights = insights
    self.generatedAt = generatedAt
  }
}

public struct MeetingTask: Codable, Identifiable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var assignee: String
  public var dueText: String
  public var isComplete: Bool
  public var source: SourceExcerpt?
  public init(title: String, source: SourceExcerpt? = nil) {
    if let source {
      let hex = Array(source.id.prefix(32))
      let groups = [
        String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]), String(hex[16..<20]),
        String(hex[20..<32]),
      ]
      id = UUID(uuidString: groups.joined(separator: "-")) ?? UUID()
    } else {
      id = UUID()
    }
    self.title = title
    assignee = ""
    dueText = ""
    isComplete = false
    self.source = source
  }
}

public struct MeetingWorkspace: Codable, Sendable {
  public var tasks: [MeetingTask] = []
  public var personalNotes = ""
  public var dismissedSources: Set<String> = []
  public init() {}
  public mutating func reconcile(_ insights: MeetingInsights) {
    var known = Set(tasks.compactMap { $0.source?.id }).union(dismissedSources)
    for source in insights.actions where known.insert(source.id).inserted {
      tasks.append(MeetingTask(title: source.text, source: source))
    }
  }
  public mutating func removeTask(_ id: UUID) {
    if let source = tasks.first(where: { $0.id == id })?.source {
      dismissedSources.insert(source.id)
    }
    tasks.removeAll { $0.id == id }
  }
  public var markdown: String {
    var sections: [String] = []
    if !tasks.isEmpty {
      let lines = tasks.map { task in
        let details = [
          task.assignee.isEmpty ? "" : "Исполнитель: \(task.assignee)",
          task.dueText.isEmpty ? "" : "Срок: \(task.dueText)",
          task.source.map { "Источник: [\(timestamp($0.start))] \($0.source.label)" } ?? "",
        ].filter { !$0.isEmpty }.map(Markdown.escaped).joined(separator: " · ")
        return "- [\(task.isComplete ? "x" : " ")] \(Markdown.escaped(task.title))"
          + (details.isEmpty ? "" : " — " + details)
      }.joined(separator: "\n")
      sections.append("## Рабочий список задач\n\n" + lines)
    }
    if !personalNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      sections.append("## Личные заметки\n\n" + personalNotes)
    }
    return sections.joined(separator: "\n\n")
  }
}

extension SessionStore {
  public func savedProtocol(_ id: UUID) throws -> SavedProtocol? {
    let file = directory(id).appendingPathComponent("protocol.json")
    if FileManager.default.fileExists(atPath: file.path) {
      return try Self.read(SavedProtocol.self, from: file)
    }
    let legacy = directory(id).appendingPathComponent("meeting.md")
    guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
    let text = try String(contentsOf: legacy, encoding: .utf8)
    return SavedProtocol(document: text, insights: .legacy(markdown: text))
  }
  public func workspace(_ id: UUID) throws -> MeetingWorkspace {
    let file = directory(id).appendingPathComponent("workspace.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return MeetingWorkspace() }
    return try Self.read(MeetingWorkspace.self, from: file)
  }
  public func saveWorkspace(_ value: MeetingWorkspace, id: UUID) throws {
    try Self.write(value, to: directory(id).appendingPathComponent("workspace.json"))
  }
  public func publish(_ value: SavedProtocol, id: UUID) throws {
    // The envelope is the commit point. The Markdown mirror remains readable by older apps.
    _ = try writeMarkdown(value.document, id: id)
    try Self.write(value, to: directory(id).appendingPathComponent("protocol.json"))
  }
}
