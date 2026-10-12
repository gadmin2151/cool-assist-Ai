import Foundation

public enum ProcessingState: String, Codable, Sendable {
  case queued, running, paused, failed
  public var label: String {
    switch self {
    case .queued: return "В очереди"
    case .running: return "Обрабатывается"
    case .paused: return "Обработка на паузе"
    case .failed: return "Нужно повторить"
    }
  }
}

public struct ProcessingJob: Codable, Identifiable, Sendable {
  public var id: UUID
  public var grounded: Bool
  public var state: ProcessingState
  public var message: String
  public var summaryOnly: Bool?
  public var summaryConfiguration: SummaryConfiguration?
  public var configuration: SummaryConfiguration { summaryConfiguration ?? SummaryConfiguration() }
  public init(
    id: UUID, grounded: Bool, summaryOnly: Bool = false,
    configuration: SummaryConfiguration = SummaryConfiguration()
  ) {
    self.id = id
    self.grounded = grounded
    self.summaryOnly = summaryOnly ? true : nil
    self.summaryConfiguration = configuration
    state = .queued
    message = "Ожидает обработки"
  }
}

public struct ProcessingUpdate: Sendable {
  public let message: String
  public let result: Transcription?
  public init(_ message: String, result: Transcription? = nil) {
    self.message = message
    self.result = result
  }
}

/// Each invocation owns one meeting's mutable data. The UI is never a processing buffer.
public struct MeetingProcessor: Sendable {
  public let store: SessionStore
  public let ai: LocalAI
  public let speech: SpeechWorker
  private let openAIKey: @Sendable () throws -> String
  private let transport: any HTTPTransport
  public init(
    store: SessionStore, ai: LocalAI, speech: SpeechWorker,
    openAIKey: @escaping @Sendable () throws -> String = {
      throw MeetingError.message("Добавьте API-ключ в настройках резюме.")
    },
    transport: any HTTPTransport = OpenAITransport()
  ) {
    self.store = store
    self.ai = ai
    self.speech = speech
    self.openAIKey = openAIKey
    self.transport = transport
  }
  private func brief(
    results: [Transcription], meeting: Meeting, job: ProcessingJob,
    directory: URL, progress: @Sendable (ProcessingUpdate) async -> Void
  ) async throws -> MeetingBrief {
    try job.configuration.validate()
    if job.configuration.provider == .openAI {
      return try await OpenAIClient(apiKey: openAIKey(), transport: transport).prepareBrief(
        results: results, meeting: meeting, model: job.configuration.model, directory: directory
      ) { text in await progress(ProcessingUpdate("OpenAI · " + text)) }
    }
    return try await ai.prepareBrief(
      results: results, meeting: meeting, directory: directory
    ) { text in await progress(ProcessingUpdate(text)) }
  }
  public func process(
    _ job: ProcessingJob, progress: @Sendable (ProcessingUpdate) async -> Void
  ) async throws {
    let directory = store.directory(job.id)
    var meeting = try SessionStore.read(
      Meeting.self, from: directory.appendingPathComponent("meeting.json"))
    guard meeting.id == job.id, meeting.duration.isFinite, meeting.duration >= 0 else {
      throw MeetingError.message("Повреждены сведения о встрече. Исходные файлы сохранены.")
    }
    let originalStatus = meeting.status
    let previous = try store.savedProtocol(job.id)
    do {
      try Task.checkCancellation()
      if job.summaryOnly == true {
        guard let previous, meeting.status == .complete else {
          throw MeetingError.message(
            "Сначала завершите расшифровку встречи, затем обновите резюме.")
        }
        let results = try store.results(job.id)
        let recognized = Set(results.map(\.id))
        guard try store.chunks(job.id).allSatisfy({ recognized.contains($0.id) }) else {
          throw MeetingError.message(
            "Расшифровка неполная. Сначала выполните «Составить протокол».")
        }
        let brief = try await brief(
          results: results, meeting: meeting, job: job,
          directory: directory.appendingPathComponent("drafts"), progress: progress)
        try Task.checkCancellation()
        var insights = previous.insights
        insights.brief = brief
        let document = Markdown.replacingBrief(in: previous.document, with: brief, meeting: meeting)
        try store.publish(SavedProtocol(document: document, insights: insights), id: job.id)
        return
      }
      let recovered = try AudioSpool.recover(folder: directory.appendingPathComponent("chunks"))
      if recovered > 0 { meeting.issues.append("Восстановлено аудиофрагментов: \(recovered).") }
      let repaired = try store.recoverResults(job.id)
      if repaired > 0 {
        meeting.issues.append("Повторное распознавание повреждённых результатов: \(repaired).")
      }
      let chunks = try store.chunks(job.id)
      meeting.duration = max(meeting.duration, chunks.map { $0.start + $0.duration }.max() ?? 0)
      var results = try store.results(job.id)
      let done = Set(results.map(\.id))
      let pending = chunks.filter { !done.contains($0.id) }
      let notes = try store.notes(job.id)
      meeting.status = .processing
      try store.save(meeting)
      for (index, chunk) in pending.enumerated() {
        try Task.checkCancellation()
        await progress(
          ProcessingUpdate(
            "Распознавание: \(index + 1) из \(pending.count) · \(timestamp(chunk.start))"))
        let result = try await ai.transcribe(
          chunk, directory: directory, language: meeting.language, worker: speech)
        try store.save(result, meetingID: job.id)
        results.append(result)
        await progress(
          ProcessingUpdate("Сохранён фрагмент \(timestamp(chunk.start))", result: result))
      }
      results.sort { $0.chunk.start < $1.chunk.start }
      let draft = Markdown.document(meeting: meeting, results: results, notes: notes)
      try SessionStore.writePrivate(
        Data(draft.utf8), to: directory.appendingPathComponent("meeting.pending.md"))
      var report: MeetingReport
      if job.configuration.provider == .openAI {
        report = MeetingReport(
          markdown: "Полная исходная речь приведена в расшифровке ниже.",
          insights: previous?.insights ?? MeetingInsights())
      } else {
        report = try await ai.prepareReport(
          results: results, notes: notes, directory: directory.appendingPathComponent("drafts"),
          grounded: job.grounded
        ) { text in await progress(ProcessingUpdate(text)) }
      }
      var brief: MeetingBrief?
      if results.contains(where: { !$0.utterances.isEmpty }) {
        brief = try await self.brief(
          results: results, meeting: meeting, job: job,
          directory: directory.appendingPathComponent("drafts"), progress: progress)
      }
      report.insights.brief = brief
      try Task.checkCancellation()
      meeting.status = .complete
      let full = Markdown.document(
        meeting: meeting, results: results, notes: notes, report: report.markdown)
      let document =
        brief.map { Markdown.replacingBrief(in: full, with: $0, meeting: meeting) } ?? full
      try store.publish(SavedProtocol(document: document, insights: report.insights), id: job.id)
      try store.save(meeting)
    } catch {
      meeting.status = originalStatus == .complete ? .complete : .captured
      if !(error is CancellationError), !meeting.issues.contains(error.localizedDescription) {
        meeting.issues.append(error.localizedDescription)
      }
      // Never replace a completed report with a failed retry or a partially written draft.
      if let previous { _ = try store.writeMarkdown(previous.document, id: job.id) }
      try store.save(meeting)
      throw error
    }
  }
}
