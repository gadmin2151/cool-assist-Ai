import Foundation

public enum SummaryProvider: String, Codable, CaseIterable, Sendable {
  case local, openAI
  public var label: String { self == .local ? "На этом Mac" : "OpenAI API" }
}

public struct SummaryConfiguration: Codable, Equatable, Sendable {
  public var provider: SummaryProvider
  public var model: String
  public init(provider: SummaryProvider = .local, model: String = "") {
    self.provider = provider
    self.model = provider == .local ? "" : model.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  public var label: String { provider == .local ? "Локально · Qwen" : "OpenAI · \(model)" }
  public func validate() throws {
    guard provider == .openAI else { return }
    guard !model.isEmpty, model.utf8.count <= 200,
      model.unicodeScalars.allSatisfy({
        CharacterSet(
          charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:/"
        ).contains($0)
      })
    else { throw MeetingError.message("Укажите модель OpenAI в настройках резюме.") }
  }
}

public struct BriefGeneration: Codable, Sendable {
  public let configuration: SummaryConfiguration
  public let createdAt: Date
  public init(configuration: SummaryConfiguration, createdAt: Date = Date()) {
    self.configuration = configuration
    self.createdAt = createdAt
  }
}
