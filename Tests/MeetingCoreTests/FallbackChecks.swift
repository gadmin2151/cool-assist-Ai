import Foundation
import MeetingCore

extension MeetingCoreChecks {
  func testBoundedSpeechStartupAndCPUFallback() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CoolAssistAi-Fallback-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let helper = folder.appendingPathComponent("meet-transcriber")
    let attempts = folder.appendingPathComponent("attempts")
    let source = folder.appendingPathComponent("audio.wav")
    let original = AudioAnalysis.wave(
      pcm: AudioAnalysis.pcm16([Float](repeating: 0.1, count: 32000)))
    try original.write(to: source)
    let script = #"""
      #!/bin/sh
      mode=gpu
      for argument in "$@"; do [ "$argument" != "--cpu" ] || mode=cpu; done
      printf '%s\n' "$mode" >> "$(dirname "$0")/attempts"
      if [ "$mode" = gpu ]; then exec /bin/sleep 20; fi
      printf '%s' '{"ready":true}' > "$4"
      while IFS= read -r request; do
        output=$(printf '%s' "$request" | /usr/bin/plutil -extract output raw -o - -)
        printf '%s' '{"transcription":[{"text":"Бюджет не утверждён.","offsets":{"from":0,"to":1000}}],"result":{"language":"ru"}}' > "$output"
      done
      """#
    try Data(script.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let paths = RuntimePaths(
      whisper: folder.appendingPathComponent("whisper-cli"), llama: helper, speechModel: helper,
      textModel: helper)
    let worker = SpeechWorker(paths: paths, startupTimeout: 2, recognitionTimeout: 2)
    for _ in 0..<2 {
      let result = try await worker.recognize(audio: source, language: "ru", directory: folder)
      let payload = try JSONDecoder().decode(WhisperResult.self, from: result)
      let chunk = AudioChunk(
        id: "fixture", source: .microphone, start: 0, duration: 2,
        features: AudioAnalysis.features([0.1]))
      try expectEqual(payload.utterances(in: chunk).first?.text, "Бюджет не утверждён.")
    }
    let usingCPU = await worker.isUsingCPU
    expect(usingCPU)
    try expectEqual(String(contentsOf: attempts, encoding: .utf8), "gpu\ncpu\n")
    try expectEqual(Data(contentsOf: source), original)
    await worker.shutdown()

    // A CPU startup failure must surface after exactly one retry, without losing audio.
    try FileManager.default.removeItem(at: attempts)
    let stalled = #"""
      #!/bin/sh
      printf 'attempt\n' >> "$(dirname "$0")/attempts"
      exec /bin/sleep 20
      """#
    try Data(stalled.utf8).write(to: helper)
    let broken = SpeechWorker(paths: paths, startupTimeout: 2, recognitionTimeout: 2)
    let started = Date()
    do {
      _ = try await broken.recognize(audio: source, language: "ru", directory: folder)
      fail("Both unavailable backends must fail")
    } catch { expect(error.localizedDescription.contains("Аудио сохранено")) }
    expectLess(Date().timeIntervalSince(started), 8)
    try expectEqual(String(contentsOf: attempts, encoding: .utf8), "attempt\nattempt\n")
    try expectEqual(Data(contentsOf: source), original)
    await broken.shutdown()
  }

  func testCLITranscriptionTimeoutRetriesCPUOnce() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CoolAssistAi-CLI-Fallback-\(UUID())")
    for path in [
      folder, folder.appendingPathComponent("chunks"), folder.appendingPathComponent("drafts"),
    ] {
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: folder) }
    let helper = folder.appendingPathComponent("whisper-cli")
    let attempts = folder.appendingPathComponent("attempts")
    let script = #"""
      #!/bin/sh
      mode=gpu
      output=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -ng) mode=cpu ;;
          -of) shift; output="$1" ;;
        esac
        shift
      done
      printf '%s\n' "$mode" >> "$(dirname "$0")/attempts"
      if [ "$mode" = gpu ]; then exec /bin/sleep 20; fi
      printf '%s' '{"transcription":[{"text":"Бюджет не утверждён.","offsets":{"from":0,"to":1000}}],"result":{"language":"ru"}}' > "$output.json"
      """#
    try Data(script.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let paths = RuntimePaths(whisper: helper, llama: helper, speechModel: helper, textModel: helper)
    let chunk = AudioChunk(
      id: "fixture", source: .microphone, start: 0, duration: 2,
      features: AudioAnalysis.features([0.1]))
    let source = folder.appendingPathComponent("chunks/fixture.wav")
    let original = AudioAnalysis.wave(
      pcm: AudioAnalysis.pcm16([Float](repeating: 0.1, count: 32000)))
    try original.write(to: source)
    let ai = LocalAI(paths: paths, speechTimeout: 2)
    let result = try await ai.transcribe(chunk, directory: folder, language: "ru")
    expectEqual(result.utterances.first?.text, "Бюджет не утверждён.")
    try expectEqual(String(contentsOf: attempts, encoding: .utf8), "gpu\ncpu\n")
    try expectEqual(Data(contentsOf: source), original)

    // Cancellation stops the first child and never launches the fallback.
    try FileManager.default.removeItem(at: attempts)
    let cancellable = LocalAI(paths: paths, speechTimeout: 10)
    let task = Task { try await cancellable.transcribe(chunk, directory: folder, language: "ru") }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
      _ = try await task.value
      fail("Expected cancellation")
    } catch { expect(error is CancellationError) }
    try expectEqual(String(contentsOf: attempts, encoding: .utf8), "gpu\n")
    try expectEqual(Data(contentsOf: source), original)
  }
}
