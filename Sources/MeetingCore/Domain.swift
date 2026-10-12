import Foundation

public enum AudioSource: String, Codable, CaseIterable, Sendable {
  case microphone, system
  public var label: String { self == .microphone ? "Микрофон" : "Звук встречи" }
}

public enum MeetingStatus: String, Codable, Sendable {
  case recording, interrupted, captured, processing, complete
  public var label: String {
    switch self {
    case .recording: return "Идёт запись"
    case .interrupted: return "Требует восстановления"
    case .captured: return "Запись сохранена"
    case .processing: return "Обработка"
    case .complete: return "Готово"
    }
  }
}

public struct Meeting: Codable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var startedAt: Date
  public var duration: Double
  public var status: MeetingStatus
  public var language: String
  public var screenRecorded: Bool
  public var issues: [String]
  public var project: String?
  public init(title: String, language: String = "auto", screenRecorded: Bool = true) {
    id = UUID()
    self.title = title
    startedAt = Date()
    duration = 0
    status = .recording
    self.language = language
    self.screenRecorded = screenRecorded
    issues = []
  }
}

public struct AcousticFeatures: Codable, Equatable, Sendable {
  public var rmsDB: Double
  public var peakDB: Double
  public var silenceRatio: Double
  public var longestPause: Double
  public var pitchChangeHz: Double?
  public var note: String {
    var parts = [String(format: "уровень %.0f dBFS", rmsDB)]
    if longestPause >= 0.8 { parts.append(String(format: "пауза до %.1f с", longestPause)) }
    if let pitchChangeHz, abs(pitchChangeHz) > 25 {
      parts.append(pitchChangeHz > 0 ? "повышение высоты голоса" : "понижение высоты голоса")
    }
    if peakDB > -1 { parts.append("перегрузка сигнала: проверьте громкость") }
    return parts.joined(separator: "; ")
  }
}

public struct AudioChunk: Codable, Identifiable, Sendable {
  public var id: String
  public var source: AudioSource
  public var start: Double
  public var duration: Double
  public var features: AcousticFeatures
  public init(
    id: String, source: AudioSource, start: Double, duration: Double, features: AcousticFeatures
  ) {
    self.id = id
    self.source = source
    self.start = start
    self.duration = duration
    self.features = features
  }
  public func validate() throws {
    guard !id.isEmpty, id.count <= 128,
      id.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
      }),
      start.isFinite, start >= 0, duration.isFinite, duration > 0, duration <= 120
    else { throw MeetingError.message("Повреждены сведения об аудиофрагменте.") }
  }
}

public struct Utterance: Codable, Equatable, Sendable {
  public var start: Double
  public var end: Double
  public var text: String
  public init(start: Double, end: Double, text: String) {
    self.start = start
    self.end = end
    self.text = text
  }
}

public struct Transcription: Codable, Identifiable, Sendable {
  public var id: String { chunk.id }
  public var chunk: AudioChunk
  public var utterances: [Utterance]
  public var language: String
  public init(chunk: AudioChunk, utterances: [Utterance], language: String) {
    self.chunk = chunk
    self.utterances = utterances
    self.language = language
  }
}

public struct TimelineNote: Codable, Identifiable, Sendable {
  public var id: UUID
  public var time: Double
  public var kind: String
  public var text: String
  public init(time: Double, kind: String, text: String) {
    id = UUID()
    self.time = time
    self.kind = kind
    self.text = text
  }
}

public enum MeetingError: LocalizedError {
  case message(String)
  public var errorDescription: String? {
    if case .message(let text) = self { return text }
    return nil
  }
}

public func timestamp(_ seconds: Double) -> String {
  let value = Int(max(0, min(Double(Int.max / 2), seconds.isFinite ? seconds : 0)))
  return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
}
