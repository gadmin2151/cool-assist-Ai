import Foundation
import MeetingCore

extension ChecksMain {
  static func parallelSmoke() async throws {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--parallel-smoke"), args.count > index + 3 else {
      throw MeetingError.message("Usage: --parallel-smoke APP-RESOURCES WAV OUTPUT")
    }
    let resources = URL(fileURLWithPath: args[index + 1])
    let audio = URL(fileURLWithPath: args[index + 2])
    let store = try SessionStore(root: URL(fileURLWithPath: args[index + 3]))
    let paths = RuntimePaths(
      whisper: resources.appendingPathComponent("Runtime/whisper-cli"),
      llama: resources.appendingPathComponent("Runtime/llama/llama-completion"),
      speechModel: resources.appendingPathComponent("Models/ggml-small-q5_1.bin"),
      textModel: resources.appendingPathComponent("Models/Qwen3-4B-Q4_K_M.gguf"))
    try paths.validate()
    let speech = SpeechWorker(paths: paths)
    let ai = LocalAI(paths: paths)
    var meeting = Meeting(
      title: "Concurrent native AI benchmark", language: "ru", screenRecorded: false)
    try store.create(meeting)
    let directory = store.directory(meeting.id)
    let data = try Data(contentsOf: audio)
    let chunk = AudioChunk(
      id: "fixture", source: .system, start: 0,
      duration: Double(data.count - 44) / 32000,
      features: AudioAnalysis.features(AudioAnalysis.floats(Data(data.dropFirst(44)))))
    try data.write(to: directory.appendingPathComponent("chunks/fixture.wav"))
    try SessionStore.write(chunk, to: directory.appendingPathComponent("chunks/fixture.json"))
    do {
      let coldStart = Date()
      let result = try await ai.transcribe(
        chunk, directory: directory, language: "ru", worker: speech)
      let cold = Date().timeIntervalSince(coldStart)
      try store.save(result, meetingID: meeting.id)
      guard !result.utterances.isEmpty else { throw MeetingError.message("No speech") }
      actor State {
        var finished = false
        func finish() { finished = true }
      }
      let state = State()
      let reportStart = Date()
      let reportTask = Task {
        let report = try await ai.prepareReport(
          results: [result], notes: [],
          directory: directory.appendingPathComponent("drafts"), grounded: false
        ) { print($0) }
        await state.finish()
        return report
      }
      try await Task.sleep(for: .milliseconds(500))
      var latencies: [Double] = []
      var overlapping = 0
      for _ in 0..<5 {
        let whileProcessing = await !state.finished
        let started = Date()
        let live = try await ai.transcribe(
          chunk, directory: directory, language: "ru", worker: speech, priority: .live)
        let time = Date().timeIntervalSince(started)
        guard !live.utterances.isEmpty else {
          throw MeetingError.message("Concurrent ASR returned no speech")
        }
        if whileProcessing { overlapping += 1 }
        latencies.append(time)
        print(
          "LIVE \(time) s for \(chunk.duration) s audio; background report active: \(whileProcessing)"
        )
      }
      let report = try await reportTask.value
      let reportSeconds = Date().timeIntervalSince(reportStart)
      let cachedStart = Date()
      let repeated = try await ai.prepareReport(
        results: [result], notes: [],
        directory: directory.appendingPathComponent("drafts"), grounded: false
      ) { _ in }
      let cachedSeconds = Date().timeIntervalSince(cachedStart)
      guard overlapping > 0, report.markdown == repeated.markdown,
        report.insights.actions.contains(where: { $0.text.contains("Анна") }),
        !report.insights.actions.contains(where: { $0.text.lowercased().contains("бюджет") }),
        report.insights.questions.contains(where: { $0.text.lowercased().contains("не утвержден") })
      else {
        throw MeetingError.message("Concurrent benchmark or grounded facts failed")
      }
      meeting.status = .complete
      meeting.duration = chunk.duration
      try store.save(meeting)
      try store.publish(
        SavedProtocol(
          document: Markdown.document(
            meeting: meeting, results: [result], notes: [], report: report.markdown),
          insights: report.insights), id: meeting.id)
      struct Metrics: Encodable {
        let audioSeconds: Double
        let coldASRSeconds: Double
        let concurrentASRSeconds: [Double]
        let overlappingRuns: Int
        let reportSeconds: Double
        let cachedReportSeconds: Double
      }
      let metrics = Metrics(
        audioSeconds: chunk.duration, coldASRSeconds: cold,
        concurrentASRSeconds: latencies, overlappingRuns: overlapping,
        reportSeconds: reportSeconds, cachedReportSeconds: cachedSeconds)
      try SessionStore.write(metrics, to: store.root.appendingPathComponent("metrics.json"))
      print(
        "PASS native concurrent ASR/report and cache: \(reportSeconds) s first report; \(cachedSeconds) s cached"
      )
      await speech.shutdown()
    } catch {
      await speech.shutdown()
      throw error
    }
  }
}
