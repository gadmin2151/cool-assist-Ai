import Foundation
import MeetingCore
import ScreenCaptureKit

private final class TestKeys: APIKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?
  func exists() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value != nil
  }
  func read() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    guard let value else { throw MeetingError.message("Missing test key") }
    return value
  }
  func save(_ key: String) throws {
    lock.lock()
    defer { lock.unlock() }
    value = key
  }
  func remove() throws {
    lock.lock()
    defer { lock.unlock() }
    value = nil
  }
}
private struct AppHTTP: HTTPTransport {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let data: Data
    if request.httpMethod == "GET" {
      data = Data(#"{"data":[{"id":"gpt-test"},{"id":"gpt-another"}]}"#.utf8)
    } else {
      let text =
        #"{"introduction":"Обсудили инструкцию.","points":[{"topic":"Инструкция","text":"Анна подготовит инструкцию.","ids":[1]}],"nextSteps":[{"topic":"Анна","text":"Подготовить инструкцию.","ids":[1]}]}"#
      data = try JSONSerialization.data(withJSONObject: [
        "status": "completed",
        "output": [
          [
            "type": "message", "role": "assistant",
            "content": [["type": "output_text", "text": text]],
          ]
        ],
      ])
    }
    return (
      data,
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}

@MainActor private final class AllowedCapture: CaptureAuthorization {
  var requests: [Bool] = []
  var pauseNextRequest = false
  var continuation: CheckedContinuation<Void, Never>?
  func authorize(requiresScreen: Bool) async throws {
    requests.append(requiresScreen)
    if pauseNextRequest {
      pauseNextRequest = false
      await withCheckedContinuation { continuation = $0 }
    }
    if requiresScreen { throw MeetingError.message("Screen access denied by test fixture") }
  }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

@MainActor private final class FixtureScreenAccess: ScreenAccessChecking {
  var preflight = false
  var requests = 0
  var failure: Error?
  var pause = false
  var continuation: CheckedContinuation<[SCDisplay], Error>?

  func preflightAllowed() -> Bool { preflight }
  func displays() async throws -> [SCDisplay] {
    requests += 1
    if pause { return try await withCheckedThrowingContinuation { continuation = $0 } }
    if let failure { throw failure }
    return []
  }
  func finish(_ result: Result<[SCDisplay], Error>) {
    continuation?.resume(with: result)
    continuation = nil
  }
}
private final class FixtureCapture: MeetingCapture {
  var onLevel: ((AudioSource, Double) -> Void)?
  var onChunk: ((AudioChunk) -> Void)?
  var onNote: ((TimelineNote) -> Void)?
  var onError: ((String) -> Void)?
  var directory: URL?
  var paused = false
  var recordScreen = false
  var useOCR = false
  var captureSystemAudio = false
  var startupError: String?
  func start(
    directory: URL, displayID: UInt32?, microphone: String?, recordScreen: Bool, useOCR: Bool,
    captureSystemAudio: Bool
  ) async throws {
    self.directory = directory
    self.recordScreen = recordScreen
    self.useOCR = useOCR
    self.captureSystemAudio = captureSystemAudio
    if let startupError {
      onError?(startupError)
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  func setPaused(_ value: Bool) async throws { paused = value }
  func stop() async throws -> Set<AudioSource> {
    captureSystemAudio ? Set(AudioSource.allCases) : [.microphone]
  }
  func emit(_ id: String, start: Double) throws {
    guard let directory, !paused else { return }
    let chunk = AudioChunk(
      id: id, source: .microphone, start: start, duration: 3,
      features: AudioAnalysis.features([0.2]))
    try SessionStore.write(chunk, to: directory.appendingPathComponent("chunks/\(id).json"))
    try AudioAnalysis.wave(pcm: AudioAnalysis.pcm16([Float](repeating: 0.1, count: 48000)))
      .write(to: directory.appendingPathComponent("chunks/\(id).wav"))
    onChunk?(chunk)
  }
}

@main enum AppModelChecks {
  @MainActor static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MeetProtocol-AppChecks-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "MeetProtocol-AppChecks-\(UUID())"
    let preferences = UserDefaults(suiteName: suite)!
    defer {
      try? FileManager.default.removeItem(at: root)
      preferences.removePersistentDomain(forName: suite)
    }
    func check(_ condition: Bool, _ message: String) throws {
      guard condition else { throw MeetingError.message("FAIL: \(message)") }
      print("PASS \(message)")
    }
    func wait(_ name: String, until condition: @MainActor () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(8)
      while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
      try check(condition(), name)
    }
    var microphoneRequests = 0
    var screenRequests = 0
    var allowMicrophone = true
    let systemAuthorization = SystemCaptureAuthorization(
      microphoneAccess: {
        microphoneRequests += 1
        return allowMicrophone
      },
      screenAccess: {
        screenRequests += 1
        throw MeetingError.message("Screen access denied by test fixture")
      })
    try await systemAuthorization.authorize(requiresScreen: false)
    try check(
      microphoneRequests == 1 && screenRequests == 0,
      "Microphone-only authorization never requests screen access")
    allowMicrophone = false
    var deniedMicrophone = false
    do {
      try await systemAuthorization.authorize(requiresScreen: true)
    } catch { deniedMicrophone = error.localizedDescription.contains("микрофону") }
    try check(
      deniedMicrophone && microphoneRequests == 2 && screenRequests == 0,
      "Denied microphone stops authorization before optional screen access")
    allowMicrophone = true
    var deniedScreen = false
    do {
      try await systemAuthorization.authorize(requiresScreen: true)
    } catch { deniedScreen = error.localizedDescription.contains("Screen access denied") }
    try check(
      deniedScreen && microphoneRequests == 3 && screenRequests == 1,
      "System-audio mode validates and propagates denied screen access")
    let executable = root.appendingPathComponent("model")
    let script = """
      #!/bin/sh
      touch started
      if [ -f fail ]; then exit 4; fi
      if [ -f slow ]; then exec /bin/sleep 20; fi
      case "$*" in
        *nextSteps*) printf '%s\\n' '{"introduction":"Обсудили выпуск инструкции.","points":[{"topic":"Инструкция","text":"Анна подготовит инструкцию.","ids":[1]}],"nextSteps":[{"topic":"Анна","text":"Подготовить инструкцию.","ids":[1]}]}' '[end of text]' ;;
        *) printf '%s\\n' '{"summary":[1],"decisions":[1],"actions":[1],"questions":[],"topics":[{"title":"Срок","ids":[1]}]}' '[end of text]' ;;
      esac
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let helper = root.appendingPathComponent("meet-transcriber")
    let asr = """
      #!/usr/bin/python3
      import sys, json, time, os
      if '--ready-file' in sys.argv:
          ready = sys.argv[sys.argv.index('--ready-file') + 1]
          with open(ready + '.writing', 'w') as f: json.dump({'ready': True}, f)
          os.replace(ready + '.writing', ready)
      for line in sys.stdin:
          value = json.loads(line)
          time.sleep(0.05)
          result = {'transcription': [{'offsets': {'from': 0, 'to': 2000}, 'text': 'Живая речь: ' + os.path.basename(value['audio'])}], 'result': {'language': 'ru'}}
          with open(value['output'] + '.writing', 'w') as f: json.dump(result, f)
          os.replace(value['output'] + '.writing', value['output'])
      """
    try Data(asr.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    try Data().write(to: root.appendingPathComponent("ggml-silero-v6.2.0.bin"))
    let paths = RuntimePaths(
      whisper: executable, llama: executable, speechModel: executable, textModel: executable)
    var captures: [FixtureCapture] = []
    var nextCaptureStartupError: String?
    let testKeys = TestKeys()
    let authorization = AllowedCapture()
    let screenAccess = FixtureScreenAccess()
    let model = try AppModel(
      root: root.appendingPathComponent("Meetings"), paths: paths,
      preferences: preferences, prewarmSpeech: false, authorization: authorization,
      screenAccessChecker: screenAccess,
      captureFactory: {
        let capture = FixtureCapture()
        capture.startupError = nextCaptureStartupError
        captures.append(capture)
        return capture
      }, keyStore: testKeys, httpTransport: AppHTTP())
    try check(
      model.screenAccess == .notChecked && screenAccess.requests == 0,
      "Unknown screen permission is not reported as denied or automatically requested")
    screenAccess.preflight = true
    model.refreshPermissions()
    await Task.yield()
    try check(
      screenAccess.requests == 0 && !model.captureSystemAudio,
      "Microphone-only focus refresh never requests ScreenCaptureKit even with positive preflight")
    screenAccess.preflight = false
    model.captureSystemAudio = true
    model.refreshPermissions()
    await Task.yield()
    try check(
      screenAccess.requests == 0,
      "False screen preflight never causes an automatic permission prompt")
    model.captureSystemAudio = false
    model.error = "Existing unrelated error"
    await model.refreshDisplays()
    model.refreshPermissions()
    try check(
      model.screenAllowed && screenAccess.requests == 1
        && model.error == "Existing unrelated error",
      "Actual SC access survives stale false preflight without clearing unrelated errors")
    let screenDenial = NSError(
      domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
    screenAccess.failure = NSError(
      domain: SCStreamErrorDomain, code: SCStreamError.Code.noDisplayList.rawValue)
    await model.refreshDisplays()
    if case .unavailable = model.screenAccess {
      try check(true, "Display enumeration failures remain distinct from denied screen permission")
    } else {
      try check(false, "Display enumeration failures remain distinct from denied screen permission")
    }
    screenAccess.failure = screenDenial
    await model.refreshDisplays()
    try check(model.screenAccess == .denied, "Actual SC denial updates the access state")
    screenAccess.preflight = true
    await model.refreshDisplays()
    try check(
      model.screenAccess == .restartRequired,
      "Positive preflight with actual SC denial provides restart guidance")
    screenAccess.preflight = false
    screenAccess.failure = nil
    screenAccess.pause = true
    let previousRequests = screenAccess.requests
    let firstCheck = Task { await model.refreshDisplays() }
    try await wait("Screen permission probe entered checking state") {
      model.screenAccess == .checking && screenAccess.continuation != nil
    }
    let secondCheck = Task { await model.refreshDisplays() }
    await Task.yield()
    screenAccess.finish(.success([]))
    await firstCheck.value
    await secondCheck.value
    try check(
      screenAccess.requests == previousRequests + 1 && model.screenAllowed,
      "Concurrent screen permission checks share one SC request")
    let staleCheck = Task { await model.refreshDisplays() }
    try await wait("Stale permission probe is suspended") { screenAccess.continuation != nil }
    model.noteScreenAuthorizationSuccess()
    screenAccess.finish(.failure(screenDenial))
    await staleCheck.value
    try check(
      model.screenAllowed, "Late failed probe cannot replace successful recording authorization")
    model.noteScreenAuthorizationFailure(NSError(domain: "Microphone", code: 1))
    try check(
      model.screenAllowed, "Unrelated capture failure does not revoke verified screen access")
    model.noteScreenAuthorizationFailure(screenDenial)
    try check(
      model.screenAccess == .denied, "Recording SC denial invalidates verified screen access")
    screenAccess.pause = false
    model.error = nil
    try check(
      model.summaryProvider == .local && !model.hasOpenAIKey,
      "Fresh install defaults to local with no API key")
    try check(model.saveAPIKey("test-openai-key-only"), "API key saves through credential store")
    try check(
      !preferences.dictionaryRepresentation().values.contains(where: {
        String(describing: $0).contains("test-openai-key-only")
      }), "API key is absent from preferences")
    await model.checkOpenAI()
    try check(
      model.availableOpenAIModels == ["gpt-another", "gpt-test"] && model.openAIError == nil,
      "Account models and connection state load")
    model.summaryProvider = .openAI
    try check(!model.summaryReady, "OpenAI requires a model choice")
    model.openAIModel = "gpt-test"
    try check(model.summaryReady, "Configured OpenAI is ready")
    model.summaryProvider = .local
    model.language = "ru"
    model.recordScreen = false
    model.useOCR = false
    model.captureSystemAudio = false
    model.microphoneID = "saved-device"
    model.displayID = 123
    model.fastProcessing = false
    let preferencesModel = try AppModel(
      root: root.appendingPathComponent("Preferences"), paths: paths,
      preferences: preferences, prewarmSpeech: false)
    try check(
      preferencesModel.language == "ru" && !preferencesModel.recordScreen
        && !preferencesModel.useOCR && !preferencesModel.captureSystemAudio
        && preferencesModel.microphoneID == "saved-device" && preferencesModel.displayID == 123
        && !preferencesModel.fastProcessing, "Recording preferences survive relaunch")
    await preferencesModel.prepareForExit()
    model.captureSystemAudio = true
    await model.start()
    try check(
      !model.isRecording && model.recordingID == nil && captures.isEmpty
        && model.meetings.isEmpty && authorization.requests == [true]
        && model.error?.contains("Screen access denied") == true,
      "Denied screen access creates no meeting or capture in system-audio mode")
    model.captureSystemAudio = false
    nextCaptureStartupError = "Microphone failed while starting test capture"
    await model.start()
    try check(
      !model.isRecording && model.canStart && model.recordingID == nil
        && model.error?.contains("Microphone failed while starting") == true
        && model.meetings.first?.status == .interrupted,
      "Capture callback failure during startup never leaves a false recording state")
    nextCaptureStartupError = nil
    model.fastProcessing = true
    func fixture(_ title: String, text: String) throws -> Meeting {
      var meeting = Meeting(title: title, language: "ru", screenRecorded: false)
      meeting.status = .complete
      meeting.duration = 3
      try model.store.create(meeting)
      let chunk = AudioChunk(
        id: "fixture", source: .system, start: 0, duration: 3,
        features: AudioAnalysis.features([0.1]))
      try SessionStore.write(
        chunk, to: model.store.directory(meeting.id).appendingPathComponent("chunks/fixture.json"))
      try model.store.save(
        Transcription(
          chunk: chunk, utterances: [Utterance(start: 0, end: 3, text: text)], language: "ru"),
        meetingID: meeting.id)
      _ = try model.store.writeMarkdown("# \(title)\nСохранённый протокол.\n", id: meeting.id)
      return meeting
    }
    let one = try fixture("Background A", text: "Анна подготовит инструкцию до четверга.")
    let two = try fixture("Workspace B", text: "Другая встреча.")
    try model.refreshLibrary()
    let original = try model.store.savedProtocol(one.id)!.document
    try Data().write(to: root.appendingPathComponent("slow"))
    model.enqueue(one.id)
    try await wait("Background AI started") {
      FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path)
    }
    model.select(two)
    try await wait("Other meeting opens during processing") {
      !model.isLoading && model.markdown.contains("Workspace B")
    }
    model.selectedTab = .notes
    let openDocument = model.markdown
    model.select(two)
    try check(
      model.selectedTab == .notes && !model.isLoading && model.markdown == openDocument,
      "Clicking the selected meeting preserves its open tab and loaded content")
    for _ in 0..<10 {
      model.select(one)
      model.select(two)
    }
    try await wait("Rapid meeting switches settle on the last selected meeting") {
      !model.isLoading && model.selectedID == two.id && model.markdown.contains("Workspace B")
    }
    var task = MeetingTask(title: "Проверить оплату")
    task.assignee = "Анна"
    task.dueText = "В пятницу"
    try check(
      model.saveTask(task, meetingID: two.id),
      "Task can be edited during another meeting's processing")
    model.toggleTask(task, meetingID: two.id)
    try check(
      model.savePersonalNotes("Моя заметка", meetingID: two.id), "Notes save during processing")
    try check(model.canStart, "Background processing does not block new recording")
    model.title = "Live C"
    model.project = "Проверка"
    model.recordScreen = true
    model.useOCR = true
    authorization.pauseNextRequest = true
    let startTask = Task { await model.start() }
    try await wait("Recording waits for the requested microphone authorization") {
      authorization.continuation != nil
    }
    model.captureSystemAudio = true
    model.recordScreen = true
    model.useOCR = true
    authorization.resume()
    await startTask.value
    let liveID = model.recordingID!
    try check(
      authorization.requests.last == false && !captures.last!.captureSystemAudio
        && !captures.last!.recordScreen && !captures.last!.useOCR
        && model.recording?.meeting.screenRecorded == false && !model.recordingSystemAudio,
      "Microphone-only capture keeps its options while settings change during authorization")
    try check(
      model.isRecording && model.job(one.id)?.state == .running,
      "Recording and background job run together")
    try captures.last!.emit("live-1", start: 0)
    try await wait("Speech is transcribed before stop while AI works") {
      model.liveText.contains("live-1")
    }
    model.select(two)
    try await wait("Navigation remains available during recording") {
      !model.isLoading && model.selectedID == two.id
    }
    try captures.last!.emit("live-2", start: 3)
    try await wait("Live ASR continues with another meeting selected") {
      model.liveText.contains("live-2")
    }
    try check(
      model.results.allSatisfy { !$0.id.hasPrefix("live-") }
        && model.markdown.contains("Workspace B"), "Live data never overwrites the selected meeting"
    )
    await model.togglePause()
    try check(
      model.isPaused && captures.last!.paused, "Pause controls work during background processing")
    await model.togglePause()
    model.markMoment()
    let stopStarted = Date()
    await model.stop()
    let stoppedMeeting = try SessionStore.read(
      Meeting.self, from: model.store.directory(liveID).appendingPathComponent("meeting.json"))
    try check(
      stoppedMeeting.issues.allSatisfy { !$0.contains(AudioSource.system.label) },
      "Stopping microphone-only capture does not report missing system audio")
    model.captureSystemAudio = false
    model.recordScreen = false
    model.useOCR = false
    try check(
      Date().timeIntervalSince(stopStarted) < 3 && model.canStart,
      "Stop releases recorder without waiting for the old report")
    try check(
      model.job(liveID)?.state == .queued && model.job(one.id)?.state == .running,
      "Stopped meeting is queued behind the existing job")
    try check(
      try model.store.notes(liveID).filter { $0.kind != "Источники записи" }.count == 3
        && model.store.notes(two.id).isEmpty,
      "Recording notes belong to the recording, not the selection")
    try check(
      try model.store.notes(liveID).contains {
        $0.kind == "Источники записи" && $0.text == "Запись только микрофона."
      }, "Microphone-only meeting preserves its source choice in the timeline")
    model.deleteMeeting(one)
    try check(
      FileManager.default.fileExists(atPath: model.store.directory(one.id).path),
      "Active job's files cannot be deleted")
    let disposable = try fixture("Disposable", text: "Empty")
    model.deleteMeeting(disposable)
    try check(
      !FileManager.default.fileExists(atPath: model.store.directory(disposable.id).path),
      "Unrelated meeting can be removed during processing")
    model.pauseJob(liveID)
    model.pauseJob(one.id)
    try await wait("Paused processing releases the background worker") { !model.isBusy }
    try check(
      try model.store.savedProtocol(one.id)?.document == original,
      "Cancellation preserves the previous completed protocol")
    try check(
      model.selectedID == two.id && model.markdown.contains("Workspace B"),
      "Finishing another job does not switch the selection")
    try FileManager.default.removeItem(at: root.appendingPathComponent("slow"))
    try Data().write(to: root.appendingPathComponent("fail"))
    model.enqueue(one.id)
    try await wait("AI failure is isolated to its job") {
      model.job(one.id)?.state == .failed && !model.isBusy
    }
    try check(
      try model.store.savedProtocol(one.id)?.document == original,
      "Failed retry preserves completed report")
    try FileManager.default.removeItem(at: root.appendingPathComponent("fail"))
    model.enqueue(one.id)
    try await wait("Retry completes the report") { model.job(one.id) == nil && !model.isBusy }
    model.select(model.meetings.first { $0.id == one.id })
    try await wait("Typed summary and action list load") {
      !model.isLoading && !model.insights.summary.isEmpty && model.workspace.tasks.count == 1
    }
    try check(
      model.markdown.contains("Анна подготовит"), "Successful job publishes report and insights")
    try check(
      model.insights.brief != nil && model.summaryText.contains("Ближайшие действия"),
      "Readable résumé and next steps are included in copy/export")
    var generatedTask = model.workspace.tasks[0]
    generatedTask.title = "Уточнённая инструкция"
    generatedTask.isComplete = true
    _ = model.saveTask(generatedTask, meetingID: one.id)
    model.enqueue(one.id)
    try await wait("Cached reprocessing completes") { model.job(one.id) == nil && !model.isBusy }
    try await wait("Completed report reloads") { !model.isLoading }
    try check(
      model.workspace.tasks.count == 1 && model.workspace.tasks[0].title == "Уточнённая инструкция"
        && model.workspace.tasks[0].isComplete, "Reprocessing preserves edits and task completion")
    let transcriptBeforeBrief = try Data(
      contentsOf: model.store.directory(one.id).appendingPathComponent("results/fixture.json"))
    try check(model.canSummarize, "Completed meeting can update just its résumé")
    model.summarizeSelected()
    model.select(two)
    try await wait("Résumé-only background job completes") {
      model.job(one.id) == nil && !model.isBusy
    }
    try check(model.selectedID == two.id, "Résumé completion preserves the other selected meeting")
    try check(
      try Data(
        contentsOf: model.store.directory(one.id).appendingPathComponent("results/fixture.json"))
        == transcriptBeforeBrief,
      "Résumé-only processing preserves transcript bytes")
    model.select(model.meetings.first { $0.id == one.id })
    try await wait("Résumé reloads with edited tasks") { !model.isLoading }
    try check(
      model.workspace.tasks.first?.isComplete == true, "Résumé refresh preserves task completion")
    model.summaryProvider = .openAI
    model.summarizeSelected()
    try check(
      model.job(one.id)?.configuration.model == "gpt-test",
      "Queued job snapshots provider and selected model")
    model.summaryProvider = .local
    model.openAIModel = "gpt-another"
    model.select(two)
    try await wait("OpenAI résumé finishes while another meeting stays open") {
      model.job(one.id) == nil && !model.isBusy
    }
    try check(model.selectedID == two.id, "API completion does not steal selection")
    model.select(model.meetings.first { $0.id == one.id })
    try await wait("OpenAI result reloads") { !model.isLoading }
    try check(
      model.insights.brief?.generation?.configuration.model == "gpt-test",
      "Result retains its actual model after settings change")
    if let action = model.insights.brief?.nextSteps.first {
      model.addBriefAction(action)
      model.addBriefAction(action)
      try check(
        model.workspace.tasks.filter { $0.title == "Анна: Подготовить инструкцию." }.count == 1,
        "Summary action preserves the assignee and creates one editable task without duplicates")
      if let added = model.workspace.tasks.first(where: { $0.title == action.taskTitle }) {
        model.deleteTask(added, meetingID: one.id)
      }
    }
    model.removeAPIKey()
    try check(
      !model.hasOpenAIKey && !testKeys.exists() && model.summaryProvider == .local,
      "Deleting API key restores local mode")
    model.deleteTask(model.workspace.tasks[0], meetingID: one.id)
    model.reloadSelected()
    try await wait("Dismissed AI task stays deleted") { !model.isLoading }
    try check(
      model.workspace.tasks.isEmpty, "Task reconciliation does not resurrect deleted actions")
    let good = model.markdown
    try Data("invalid".utf8).write(
      to: model.store.directory(one.id).appendingPathComponent("results/fixture.json"))
    model.reloadSelected()
    try await wait("Corrupt transcript load settles") { !model.isLoading }
    try check(
      model.error != nil && model.markdown == good,
      "Damaged transcript does not hide completed protocol")
    model.select(nil)
    try check(
      model.selectedTab == .overview && model.markdown.isEmpty && model.error == nil,
      "New meeting clears only the selected workspace")
    // A saved paused job and edited tasks survive a controlled restart.
    await model.prepareForExit()
    let restored = try AppModel(
      root: model.store.root, paths: paths, preferences: preferences, prewarmSpeech: false)
    try check(restored.job(liveID)?.state == .paused, "Paused queue survives relaunch")
    restored.select(two)
    try await wait("Task workspace restored") { !restored.isLoading }
    try check(
      restored.workspace.tasks.first?.isComplete == true
        && restored.workspace.personalNotes == "Моя заметка",
      "Task completion and notes survive relaunch")
    restored.enqueue(liveID)
    try await wait("Queued live meeting completes after relaunch") {
      restored.job(liveID) == nil && !restored.isBusy
    }
    let resumeMeeting = try fixture("Resume on quit", text: "Продолжить отчёт после перезапуска.")
    try restored.refreshLibrary()
    try Data().write(to: root.appendingPathComponent("slow"))
    restored.enqueue(resumeMeeting.id)
    try await wait("Job is running before application exit") {
      restored.job(resumeMeeting.id)?.state == .running
    }
    let exitStarted = Date()
    await restored.prepareForExit()
    try check(
      Date().timeIntervalSince(exitStarted) < 3, "Application exit cancels owned workers promptly")
    let savedQueue = try SessionStore.read(
      [ProcessingJob].self, from: model.store.root.appendingPathComponent("processing-queue.json"))
    try check(
      savedQueue.first(where: { $0.id == resumeMeeting.id })?.state == .queued,
      "Running job is saved for automatic continuation")
    try FileManager.default.removeItem(at: root.appendingPathComponent("slow"))
    let automatic = try AppModel(
      root: model.store.root, paths: paths, preferences: preferences, prewarmSpeech: false)
    try await wait("Saved running job automatically resumes after relaunch") {
      automatic.job(resumeMeeting.id) == nil && !automatic.isBusy
    }
    await automatic.prepareForExit()
    try Data("broken queue".utf8).write(
      to: model.store.root.appendingPathComponent("processing-queue.json"))
    let recoveredQueue = try AppModel(
      root: model.store.root, paths: paths, preferences: preferences, prewarmSpeech: false)
    try check(
      recoveredQueue.error?.contains("Файл очереди повреждён") == true
        && !recoveredQueue.meetings.isEmpty, "Damaged queue does not prevent opening the library")
    await recoveredQueue.prepareForExit()
    let nativeKeys = KeychainAPIKeyStore(service: "cc.idomus.meet-protocol.tests.\(UUID())")
    defer { try? nativeKeys.remove() }
    try nativeKeys.save("fixture-key-not-valid")
    try check(
      nativeKeys.exists() && (try nativeKeys.read()) == "fixture-key-not-valid",
      "Native Keychain saves and reads an isolated test credential")
    try nativeKeys.save("replacement-fixture-key")
    try check(
      try nativeKeys.read() == "replacement-fixture-key",
      "Native Keychain updates existing credential")
    try nativeKeys.remove()
    try check(!nativeKeys.exists(), "Native Keychain removes only the test credential")
    print("All AppModel concurrent workflow checks passed.")
  }
}
