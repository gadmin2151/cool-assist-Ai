import Foundation
import MeetingCore

// Standalone test harness: works with Command Line Tools, which do not ship XCTest.
private var failures: [String] = []
func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
  failures.append("\(file):\(line): \(message)")
}
func expect(
  _ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line
) rethrows {
  if try !condition() { fail("Expectation failed", file: file, line: line) }
}
func expectFalse(
  _ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line
) rethrows { try expect(!condition(), file: file, line: line) }
func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
  expect(value == nil, file: file, line: line)
}
func expectEqual<T: Equatable>(
  _ lhs: @autoclosure () throws -> T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line
) rethrows {
  let value = try lhs()
  if value != rhs { fail("\(value) != \(rhs)", file: file, line: line) }
}
func expectEqual<T: BinaryFloatingPoint>(
  _ lhs: T, _ rhs: T, accuracy: T, file: StaticString = #filePath, line: UInt = #line
) { expect(abs(lhs - rhs) <= accuracy, file: file, line: line) }
func expectGreater<T: Comparable>(
  _ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line
) { expect(lhs > rhs, file: file, line: line) }
func expectLess<T: Comparable>(
  _ lhs: T, _ rhs: T, file: StaticString = #filePath, line: UInt = #line
) { expect(lhs < rhs, file: file, line: line) }

@main enum ChecksMain {
  static func main() async {
    if CommandLine.arguments.contains("--brief-smoke") {
      do {
        try await briefSmoke()
        exit(0)
      } catch {
        print(error)
        exit(1)
      }
    }
    if CommandLine.arguments.contains("--parallel-smoke") {
      do {
        try await parallelSmoke()
        exit(0)
      } catch {
        print(error)
        exit(1)
      }
    }
    if CommandLine.arguments.contains("--editorial-smoke") {
      do {
        try await editorialSmoke()
        exit(0)
      } catch {
        print(error)
        exit(1)
      }
    }
    if CommandLine.arguments.contains("--resident-smoke") {
      do {
        try await residentSmoke()
        exit(0)
      } catch {
        print(error)
        exit(1)
      }
    }
    if CommandLine.arguments.contains("--stress") {
      do {
        try stressAudio()
        if !failures.isEmpty {
          for failure in failures { print(failure) }
          exit(1)
        }
        exit(0)
      } catch {
        print(error)
        exit(1)
      }
    }
    let suite = MeetingCoreChecks()
    let cases: [(String, () throws -> Void)] = [
      (
        "Résumé exact evidence and conservative cross-channel echo removal",
        suite.testBriefEvidenceAndConservativeEchoRemoval
      ),
      (
        "Oversized callbacks retain every PCM sample within ASR limits",
        suite.testOversizedAudioCallbacksRemainBoundedAndLossless
      ),
      (
        "ASR timestamps and non-speech markers",
        suite.testRecognitionRejectsInvalidTimesAndBlankAudioMarkers
      ),
      (
        "Résumé compatibility and original document preservation",
        suite.testBriefCompatibilityAndDocumentPreservation
      ),
      ("Workspace compatibility and task reconciliation", suite.testWorkspaceCompatibilityAndMerge),
      (
        "Corrupt result recovery preserves evidence",
        suite.testCorruptResultsCanBeRetriedWithoutDiscardingEvidence
      ),
      (
        "Meeting identity and audio path validation",
        suite.testMetadataCannotRedirectToAnotherMeetingOrPath
      ),
      ("Resident helper preflight", suite.testMissingResidentHelperIsDetectedBeforeRecording),
      ("WAV format, clipping, invalid samples", suite.testWAVHeaderClippingAndInvalidSamples),
      ("Acoustic measurements", suite.testAcousticsDoNotInferEmotion),
      ("Crash recovery and idempotency", suite.testRecoveryOfUnfinishedPCMAndIdempotency),
      ("Segment boundaries and short tail", suite.testSilenceBoundaryAndTailNeverLoseSamples),
      ("Pause timestamp gap", suite.testPauseGapPreservesWallClockTimestamps),
      ("Live segments before stop", suite.testLiveSegmentsAreAvailableBeforeRecordingStops),
      (
        "Three-hour transcript and Unicode",
        suite.testMultiHourTranscriptBatchesPreserveUnicodeAndLateDecisions
      ),
      (
        "Full transcript and incomplete result",
        suite.testMarkdownKeepsFullOriginalAlongsideSummaryAndFlagsMissingAudio
      ),
      ("Persistence and file permissions", suite.testSessionPersistencePermissionsAndSeparation),
      (
        "Selective, recoverable deletion",
        suite.testTrashRemovesOnlySelectedMeetingAndPreservesFiles
      ),
    ]
    for (name, test) in cases {
      let before = failures.count
      do { try test() } catch { fail(error.localizedDescription) }
      print("\(failures.count == before ? "PASS" : "FAIL") \(name)")
    }
    do {
      try await suite.testOpenAIRequestPrivacyAndCache()
      print("PASS OpenAI Responses contract, credentials isolation and cache")
      try await suite.testOpenAIFailuresCancellationAndModels()
      print("PASS OpenAI errors, bounded retry, cancellation and model discovery")
      try await suite.testOpenAIProcessorPreservesSourcesAndWorkspace()
      print(
        "PASS OpenAI processing preserves speech, private notes, tasks and old report on failure")
    } catch { fail(error.localizedDescription) }
    do {
      try await suite.testBriefValidationAndLongMeeting()
      print("PASS Résumé source validation, repetition rejection and bounded long meeting")
    } catch { fail(error.localizedDescription) }
    do {
      try await suite.testProcessTimeoutAndCancellationDoNotHang()
      print("PASS Process timeout and cancellation")
    } catch { fail(error.localizedDescription) }
    do {
      try await suite.testEditorialReportKeepsGroundedFactsAndBoundedPasses()
      print("PASS Editorial facts protected; bounded short and long meeting passes")
    } catch { fail(error.localizedDescription) }
    do {
      try await suite.testGroundedReportRejectsInventedIDsAndKeepsUnassignedSpeech()
      print("PASS Grounded report and omitted source recovery")
    } catch { fail(error.localizedDescription) }
    do {
      try await suite.testPersistentSpeechCancellationAndEarlyExit()
      print("PASS Persistent speech cancellation and child failure")
    } catch { fail(error.localizedDescription) }
    do {
      try await suite.testBoundedSpeechStartupAndCPUFallback()
      try await suite.testCLITranscriptionTimeoutRetriesCPUOnce()
      print("PASS Bounded CPU fallback, preserved audio and cancellation")
    } catch { fail(error.localizedDescription) }
    do {
      try await suite.testInferencePriorityAndCancellation()
      print("PASS Live inference priority and cancelled waiter")
      try await suite.testGenerationCacheResumptionAndInvalidation()
      print("PASS Generation cache resume, changed inputs, corruption and model change")
    } catch { fail(error.localizedDescription) }
    for teardown in suite.teardowns {
      do { try teardown() } catch { fail(error.localizedDescription) }
    }
    if !failures.isEmpty {
      for failure in failures { print(failure) }
      exit(1)
    }
    print("All \(cases.count + 12) checks passed.")
  }

  static func residentSmoke() async throws {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--resident-smoke"), arguments.count > index + 2
    else {
      throw MeetingError.message("Usage: --resident-smoke WAV APP-RESOURCES")
    }
    let input = URL(fileURLWithPath: arguments[index + 1])
    let resources = URL(fileURLWithPath: arguments[index + 2])
    let paths = RuntimePaths(
      whisper: resources.appendingPathComponent("Runtime/whisper-cli"),
      llama: resources.appendingPathComponent("Runtime/llama/llama-completion"),
      speechModel: resources.appendingPathComponent("Models/ggml-small-q5_1.bin"),
      textModel: resources.appendingPathComponent("Models/Qwen3-4B-Q4_K_M.gguf"))
    try paths.validate()
    let worker = SpeechWorker(paths: paths)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MeetProtocol-ResidentCheck-\(UUID())")
    let store = try SessionStore(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      let meeting = Meeting(title: "Resident engine validation")
      try store.create(meeting)
      let directory = store.directory(meeting.id)
      try FileManager.default.copyItem(
        at: input, to: directory.appendingPathComponent("chunks/fixture.wav"))
      let data = try Data(contentsOf: input)
      let chunk = AudioChunk(
        id: "fixture", source: .system, start: 0,
        duration: Double(max(0, data.count - 44)) / 32000,
        features: AudioAnalysis.features(AudioAnalysis.floats(Data(data.dropFirst(44)))))
      for run in 1...2 {
        let started = Date()
        let result = try await LocalAI(paths: paths).transcribe(
          chunk, directory: directory, language: "auto", worker: worker)
        guard !result.utterances.isEmpty else {
          throw MeetingError.message("No speech returned by resident engine")
        }
        print(
          "PASS resident engine run \(run): \(result.utterances.count) utterances, \(Date().timeIntervalSince(started)) s"
        )
      }
      await worker.shutdown()
    } catch {
      await worker.shutdown()
      throw error
    }
  }

  static func editorialSmoke() async throws {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--editorial-smoke"), args.count > index + 3 else {
      throw MeetingError.message(
        "Usage: --editorial-smoke APP-RESOURCES MEETING-DIRECTORY OUTPUT-DIRECTORY")
    }
    let resources = URL(fileURLWithPath: args[index + 1])
    let directory = URL(fileURLWithPath: args[index + 2])
    let output = URL(fileURLWithPath: args[index + 3])
    guard let id = UUID(uuidString: directory.lastPathComponent) else {
      throw MeetingError.message("Invalid fixture ID")
    }
    let store = try SessionStore(root: directory.deletingLastPathComponent())
    let paths = RuntimePaths(
      whisper: resources.appendingPathComponent("Runtime/whisper-cli"),
      llama: resources.appendingPathComponent("Runtime/llama/llama-completion"),
      speechModel: resources.appendingPathComponent("Models/ggml-small-q5_1.bin"),
      textModel: resources.appendingPathComponent("Models/Qwen3-4B-Q4_K_M.gguf"))
    try paths.validate()
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let started = Date()
    let report = try await LocalAI(paths: paths).report(
      results: store.results(id), notes: [],
      directory: output, grounded: false
    ) { print($0) }
    try SessionStore.writePrivate(Data(report.utf8), to: output.appendingPathComponent("report.md"))
    let actions = report.components(separatedBy: "### Поручения")[1].components(
      separatedBy: "### Открытые вопросы")[0]
    guard actions.contains("Анна"), !actions.lowercased().contains("бюджет"),
      report.components(separatedBy: "### Открытые вопросы")[1].contains("не утвержден")
    else {
      throw MeetingError.message("Fixture facts were incorrectly classified")
    }
    print(
      "PASS editorial fixture: source actions preserved, unresolved budget retained; \(Date().timeIntervalSince(started)) s"
    )
  }

  static func stressAudio() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MeetSecretarStress-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var count = 0
    var duration: [AudioSource: Double] = [:]
    let spools = AudioSource.allCases.map { source in
      let spool = AudioSpool(folder: root, source: source, minimumDuration: 3, maximumDuration: 8)
      spool.onChunk = { chunk in
        count += 1
        duration[chunk.source, default: 0] += chunk.duration
      }
      return spool
    }
    let second = [Float](repeating: 0, count: 16000)
    let started = Date()
    for time in 0..<10800 {
      for spool in spools { try spool.append(second, at: Double(time)) }
    }
    for spool in spools { try spool.finish() }
    expectEqual(count, 7200)
    for source in AudioSource.allCases { expectEqual(duration[source], 10800) }
    let files = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.fileSizeKey])
    let bytes = try files.filter { $0.pathExtension == "wav" }.reduce(0) {
      try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    expectEqual(bytes, 10800 * 32000 * 2 + 7200 * 44)
    print(
      "PASS 3 hours × 2 channels: \(count) durable chunks, \(bytes) WAV bytes, \(Date().timeIntervalSince(started)) s accelerated runtime."
    )
  }
}
