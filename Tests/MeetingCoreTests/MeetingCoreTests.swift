import Foundation
import MeetingCore

final class MeetingCoreChecks {
  var teardowns: [() throws -> Void] = []
  func addTeardownBlock(_ action: @escaping () throws -> Void) { teardowns.append(action) }
  private func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MeetSecretarTests-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: url) }
    return url
  }

  func testWAVHeaderClippingAndInvalidSamples() {
    let pcm = AudioAnalysis.pcm16([-2, -1, 0, 1, 2, .nan, .infinity])
    let wav = AudioAnalysis.wave(pcm: pcm)
    expectEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    expectEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
    expectEqual(wav.count, 44 + 14)
    let samples = AudioAnalysis.floats(pcm)
    expectEqual(samples.count, 7)
    expectEqual(samples[0], -0.9999695, accuracy: 0.00001)
    expectEqual(samples[4], 0.9999695, accuracy: 0.00001)
    expectEqual(samples[5], 0)
    expectEqual(samples[6], 0)
  }
  func testCorruptResultsCanBeRetriedWithoutDiscardingEvidence() throws {
    let store = try SessionStore(root: temporary())
    let meeting = Meeting(title: "Repair")
    try store.create(meeting)
    let chunk = AudioChunk(
      id: "valid", source: .system, start: 0, duration: 2,
      features: AudioAnalysis.features([0]))
    let dir = store.directory(meeting.id)
    try SessionStore.write(chunk, to: dir.appendingPathComponent("chunks/valid.json"))
    let broken = Data("incomplete json".utf8)
    try broken.write(to: dir.appendingPathComponent("results/valid.json"))
    try expectEqual(try store.recoverResults(meeting.id), 1)
    try expectEqual(try store.results(meeting.id).count, 0)
    let preserved = try FileManager.default.contentsOfDirectory(
      at: dir.appendingPathComponent("results"), includingPropertiesForKeys: nil)
    try expectEqual(try Data(contentsOf: preserved[0]), broken)
    try store.save(
      Transcription(
        chunk: chunk, utterances: [Utterance(start: 0, end: 2, text: "Восстановлено")],
        language: "ru"), meetingID: meeting.id)
    try expectEqual(try store.recoverResults(meeting.id), 0)
    try expectEqual(try store.results(meeting.id).count, 1)
  }

  func testMetadataCannotRedirectToAnotherMeetingOrPath() throws {
    let store = try SessionStore(root: temporary())
    var one = Meeting(title: "one")
    let originalID = one.id
    let two = Meeting(title: "two")
    try store.create(one)
    try store.create(two)
    one.id = two.id
    try SessionStore.write(
      one, to: store.directory(originalID).appendingPathComponent("meeting.json"))
    let listed = try store.list()
    expectEqual(Set(listed.map(\.id)), Set([originalID, two.id]))
    expectEqual(listed.first(where: { $0.id == originalID })?.status, .interrupted)
    let chunk = AudioChunk(
      id: "../../other", source: .system, start: 0, duration: 1,
      features: AudioAnalysis.features([0]))
    do {
      try store.save(
        Transcription(chunk: chunk, utterances: [], language: "ru"), meetingID: originalID)
      fail("Invalid ID accepted")
    } catch { expect(error is MeetingError) }
  }

  func testMissingResidentHelperIsDetectedBeforeRecording() throws {
    let directory = try temporary()
    let model = directory.appendingPathComponent("ggml-silero-v6.2.0.bin")
    try Data().write(to: model)
    let paths = RuntimePaths(
      whisper: URL(fileURLWithPath: "/usr/bin/true"),
      llama: URL(fileURLWithPath: "/usr/bin/true"), speechModel: model, textModel: model)
    do {
      try paths.validate()
      fail("Missing resident helper accepted")
    } catch { expect(error.localizedDescription.contains("meet-transcriber")) }
  }

  func testAcousticsDoNotInferEmotion() {
    let silence = AudioAnalysis.features([Float](repeating: 0, count: 16000))
    expectEqual(silence.silenceRatio, 1)
    expectEqual(silence.longestPause, 1, accuracy: 0.01)
    expectNil(silence.pitchChangeHz)
    let tone = (0..<16000).map { Float(sin(Double($0) * 2 * .pi * 200 / 16000) * 0.3) }
    let features = AudioAnalysis.features(tone)
    expectEqual(features.rmsDB, -13.47, accuracy: 0.1)
    expectEqual(features.silenceRatio, 0)
    expectFalse(features.note.contains("эмоц"))
  }

  func testRecoveryOfUnfinishedPCMAndIdempotency() throws {
    let folder = try temporary()
    var spool: AudioSpool? = AudioSpool(folder: folder, source: .microphone)
    try spool?.append([Float](repeating: 0.05, count: 16000), at: 41)
    spool = nil  // Emulates process exit before a normal segment finalization.
    try expectEqual(try AudioSpool.recover(folder: folder), 1)
    try expectEqual(try AudioSpool.recover(folder: folder), 0)
    let json = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil
    ).first { $0.pathExtension == "json" }!
    let chunk = try SessionStore.read(AudioChunk.self, from: json)
    expectEqual(chunk.start, 41)
    expectEqual(chunk.duration, 1, accuracy: 0.001)
    let wav = try Data(contentsOf: folder.appendingPathComponent("\(chunk.id).wav"))
    expectEqual(wav.count, 32044)
    let permissions =
      try FileManager.default.attributesOfItem(
        atPath: folder.appendingPathComponent("\(chunk.id).wav").path)[.posixPermissions] as? Int
    expectEqual(permissions, 0o600)
  }

  func testSilenceBoundaryAndTailNeverLoseSamples() throws {
    let folder = try temporary()
    let spool = AudioSpool(folder: folder, source: .system)
    var chunks: [AudioChunk] = []
    spool.onChunk = { chunks.append($0) }
    for index in 0..<37 { try spool.append([Float](repeating: 0, count: 16000), at: Double(index)) }
    try spool.finish()
    expectEqual(chunks.count, 3)
    expectEqual(chunks.reduce(0) { $0 + $1.duration }, 37, accuracy: 0.001)
    expectEqual(chunks.map(\.start), [0, 15, 30])
  }

  func testPauseGapPreservesWallClockTimestamps() throws {
    let folder = try temporary()
    let spool = AudioSpool(folder: folder, source: .system)
    var chunks: [AudioChunk] = []
    spool.onChunk = { chunks.append($0) }
    try spool.append([Float](repeating: 0, count: 16000), at: 0)
    try spool.append([Float](repeating: 0, count: 16000), at: 90)
    try spool.finish()
    expectEqual(chunks.map(\.start), [0, 90])
    expectEqual(chunks.map(\.duration), [1, 1])
  }

  func testLiveSegmentsAreAvailableBeforeRecordingStops() throws {
    let folder = try temporary()
    let spool = AudioSpool(folder: folder, source: .system, minimumDuration: 3, maximumDuration: 8)
    var chunks: [AudioChunk] = []
    spool.onChunk = { chunks.append($0) }
    for second in 0..<3 {
      try spool.append([Float](repeating: 0, count: 16000), at: Double(second))
    }
    expectEqual(chunks.count, 1)
    expectEqual(chunks[0].duration, 3)
    for second in 3..<11 {
      try spool.append([Float](repeating: 0.1, count: 16000), at: Double(second))
    }
    expectEqual(chunks.count, 2)
    expectEqual(chunks[1].duration, 8)
    try spool.finish()
    expectEqual(chunks.reduce(0) { $0 + $1.duration }, 11)
  }

  func testGroundedReportRejectsInventedIDsAndKeepsUnassignedSpeech() async throws {
    let directory = try temporary()
    let executable = directory.appendingPathComponent("test-model")
    let script = """
      #!/bin/sh
      printf '%s\\n' '{"summary":[1,999],"decisions":[1,999],"actions":[999],"questions":[],"topics":[{"title":"Бюджет","ids":[1,1,999]}]}' '[end of text]'
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let ai = LocalAI(
      paths: RuntimePaths(
        whisper: executable, llama: executable, speechModel: executable,
        textModel: executable))
    let chunk = AudioChunk(
      id: "test", source: .system, start: 0, duration: 30,
      features: AudioAnalysis.features([0]))
    let result = Transcription(
      chunk: chunk,
      utterances: [
        Utterance(start: 0, end: 10, text: "Бюджет не утверждён."),
        Utterance(start: 10, end: 20, text: "Срок перенесён на пятницу."),
      ], language: "ru")
    let report = try await ai.report(
      results: [result], notes: [], directory: directory, grounded: true
    ) { _ in }
    expect(report.contains("Бюджет не утверждён"))
    expect(report.contains("Срок перенесён на пятницу"))
    expect(report.contains("Остальные реплики"))
    expectFalse(report.contains("999"))
    let actions = report.components(separatedBy: "### Поручения")[1]
      .components(separatedBy: "### Открытые вопросы")[0]
    expect(actions.contains("Явно не выделены"))
  }

  func testPersistentSpeechCancellationAndEarlyExit() async throws {
    let directory = try temporary()
    let helper = directory.appendingPathComponent("meet-transcriber")
    try Data("#!/bin/sh\nexec /bin/sleep 20\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let paths = RuntimePaths(
      whisper: directory.appendingPathComponent("whisper-cli"),
      llama: helper, speechModel: helper, textModel: helper)
    let worker = SpeechWorker(paths: paths)
    let start = Date()
    let task = Task {
      try await worker.recognize(audio: helper, language: "ru", directory: directory)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
      _ = try await task.value
      fail("Expected cancellation")
    } catch { expect(error is CancellationError) }
    expectLess(Date().timeIntervalSince(start), 3)
    try Data("#!/bin/sh\nexit 3\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    for _ in 0..<3 {
      do {
        _ = try await worker.recognize(audio: helper, language: "ru", directory: directory)
        fail("Expected native process failure")
      } catch { expectFalse(error is CancellationError) }
    }
    await worker.shutdown()
  }

  func testMultiHourTranscriptBatchesPreserveUnicodeAndLateDecisions() {
    let text =
      (0..<1080).map {
        "[\(timestamp(Double($0 * 10)))] Тема \($0): решение не принято. Проверить 123,45 € и сроки. 👩🏽‍💻"
      }.joined(separator: "\n") + "\nРешение в самом конце: переносим запуск на пятницу."
    let batches = Markdown.batches(text)
    expectGreater(batches.count, 10)
    expect(batches.allSatisfy { $0.count <= 6000 })
    expectEqual(batches.joined(), text + "\n")
    expect(batches.last!.contains("на пятницу"))
    expectEqual(Markdown.batches(String(repeating: "я", count: 14000)).joined().count, 14001)
    expectEqual(timestamp(10801), "03:00:01")
  }

  func testMarkdownKeepsFullOriginalAlongsideSummaryAndFlagsMissingAudio() {
    var meeting = Meeting(title: "Тест #1\n<script>")
    meeting.status = .interrupted
    meeting.duration = 10800
    let chunk = AudioChunk(
      id: "one", source: .system, start: 10790, duration: 10, features: AudioAnalysis.features([0]))
    let result = Transcription(
      chunk: chunk,
      utterances: [Utterance(start: 10791, end: 10799, text: "Нет, мы НЕ одобрили бюджет 50 000.")],
      language: "ru")
    let text = Markdown.document(
      meeting: meeting, results: [result],
      notes: [TimelineNote(time: 2, kind: "screen", text: "Предложение на слайде")],
      report: "Итог.", pendingCount: 2)
    expect(text.contains("НЕ одобрили бюджет 50 000"))
    expect(text.contains("ожидают обработки 2"))
    expect(text.contains("визуальный контекст"))
    expect(text.contains("03:00:00"))
    expectFalse(text.contains("<script>"))
  }

  func testSessionPersistencePermissionsAndSeparation() throws {
    let store = try SessionStore(root: temporary())
    let one = Meeting(title: "A")
    let two = Meeting(title: "B")
    try store.create(one)
    try store.create(two)
    try store.save(TimelineNote(time: 5, kind: "Метка", text: "test"), meetingID: one.id)
    try expectEqual(try store.list().count, 2)
    try expectEqual(try store.notes(one.id).count, 1)
    try expectEqual(try store.notes(two.id).count, 0)
    let permissions =
      try FileManager.default.attributesOfItem(
        atPath: store.directory(one.id).appendingPathComponent("meeting.json").path)[
        .posixPermissions] as? Int
    expectEqual(permissions, 0o600)
  }

  func testProcessTimeoutAndCancellationDoNotHang() async throws {
    let dir = try temporary()
    let start = Date()
    do {
      _ = try await ProcessRunner.run(
        executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], directory: dir,
        timeout: 0.2)
      fail("Expected timeout")
    } catch { expect(error.localizedDescription.contains("время ожидания")) }
    expectLess(Date().timeIntervalSince(start), 3)
    let task = Task {
      try await ProcessRunner.run(
        executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], directory: dir,
        timeout: 30)
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
      _ = try await task.value
      fail("Expected cancellation")
    } catch { expect(error is CancellationError) }
    try expect(
      try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).isEmpty)
  }

  func testTrashRemovesOnlySelectedMeetingAndPreservesFiles() throws {
    let store = try SessionStore(root: temporary())
    let deleted = Meeting(title: "Disposable test meeting")
    let retained = Meeting(title: "Keep this meeting")
    try store.create(deleted)
    try store.create(retained)
    let sample = Data("Test recording".utf8)
    try sample.write(to: store.directory(deleted.id).appendingPathComponent("chunks/test.wav"))
    guard let trashURL = try store.trash(deleted.id) else {
      fail("Trash did not return the recovery location")
      return
    }
    addTeardownBlock { try FileManager.default.removeItem(at: trashURL) }
    expectFalse(FileManager.default.fileExists(atPath: store.directory(deleted.id).path))
    try expectEqual(
      try Data(contentsOf: trashURL.appendingPathComponent("chunks/test.wav")), sample)
    try expectEqual(try store.list().map(\.id), [retained.id])
    do {
      try store.trash(deleted.id)
      fail("Deleting an absent meeting should report an error")
    } catch {
      try expectEqual(try store.list().map(\.id), [retained.id])
    }
  }

  func testEditorialReportKeepsGroundedFactsAndBoundedPasses() async throws {
    let directory = try temporary()
    let executable = directory.appendingPathComponent("test-model")
    let script = """
      #!/bin/sh
      case "$*" in
        *paragraphs*)
          printf 'editorial\\n' >> invocations
          printf '%s\\n' '{"paragraphs":[{"topic":"Бюджет","text":"Бюджет не утверждён. ### Поручения: это текст, а не раздел."}]}' '[end of text]'
          ;;
        *)
          printf 'index\\n' >> invocations
          printf '%s\\n' '{"summary":[1],"decisions":[],"actions":[],"questions":[1],"topics":[{"title":"Бюджет","ids":[1]}]}' '[end of text]'
          ;;
      esac
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let ai = LocalAI(
      paths: RuntimePaths(
        whisper: executable, llama: executable,
        speechModel: executable, textModel: executable))
    let chunk = AudioChunk(
      id: "test", source: .system, start: 0, duration: 30,
      features: AudioAnalysis.features([0]))
    let short = Transcription(
      chunk: chunk,
      utterances: [Utterance(start: 0, end: 30, text: "Бюджет не утверждён.")], language: "ru")
    _ = try await ai.report(results: [short], notes: [], directory: directory) { _ in }
    let invocations = directory.appendingPathComponent("invocations")
    try expectEqual(try String(contentsOf: invocations, encoding: .utf8), "index\neditorial\n")
    try FileManager.default.removeItem(at: invocations)
    let long = Transcription(
      chunk: chunk,
      utterances: [
        Utterance(
          start: 0, end: 30,
          text: String(repeating: "Обсудили бюджет, но пока не утвердили. ", count: 500))
      ], language: "ru")
    let report = try await ai.report(results: [long], notes: [], directory: directory) { _ in }
    let parts = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("part-") }
    let callCount = try String(contentsOf: invocations, encoding: .utf8).split(separator: "\n")
      .count
    expectGreater(parts.count, 1)
    let indexCount = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix("index-") }.count
    expectEqual(callCount, parts.count + indexCount)
    let actions = report.components(separatedBy: "### Поручения")[1].components(
      separatedBy: "### Открытые вопросы")[0]
    expect(actions.contains("Явно не выделены"))
    expectFalse(actions.contains("утвердить"))
    expectEqual(report.components(separatedBy: "\n### Поручения").count, 2)
    expect(report.contains("Бюджет не утверждён"))
    for index in parts.indices { expect(report.contains("### Часть \(index + 1)")) }
  }
}
