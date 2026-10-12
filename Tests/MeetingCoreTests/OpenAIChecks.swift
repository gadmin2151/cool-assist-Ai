import Foundation
import MeetingCore

actor StubHTTP: HTTPTransport {
  struct Reply: Sendable {
    let status: Int
    let data: Data
  }
  var replies: [Reply]
  var requests: [URLRequest] = []
  var delay: Double
  init(_ replies: [Reply], delay: Double = 0) {
    self.replies = replies
    self.delay = delay
  }
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
    let reply = replies.removeFirst()
    return (
      reply.data,
      HTTPURLResponse(
        url: request.url!, statusCode: reply.status,
        httpVersion: nil, headerFields: ["Retry-After": "1"])!
    )
  }
  func count() -> Int { requests.count }
  func first() -> URLRequest? { requests.first }
}

extension MeetingCoreChecks {
  private func apiTemporary() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MeetProtocol-APIChecks-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
  private func apiReply(status: String = "completed", text: String = #"{"value":"готово"}"#) throws
    -> StubHTTP.Reply
  {
    let data = try JSONSerialization.data(withJSONObject: [
      "status": status,
      "output": [
        ["type": "reasoning"],
        [
          "type": "message", "role": "assistant",
          "content": [["type": "output_text", "text": text]],
        ],
      ],
    ])
    return StubHTTP.Reply(status: 200, data: data)
  }
  func testOpenAIRequestPrivacyAndCache() async throws {
    let root = try apiTemporary()
    let transport = try StubHTTP([apiReply(), apiReply(), apiReply()])
    let key = "test-openai-key-not-real"
    let client = try OpenAIClient(apiKey: key, transport: transport)
    let schema =
      #"{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}"#
    func generate(_ input: String = "Только речь", model: String = "gpt-test") async throws
      -> String
    {
      try await client.generate(
        instruction: "Резюме", input: input, schema: schema, model: model, directory: root)
    }
    let first = try await generate()
    let cached = try await generate()
    expectEqual(first, cached)
    let count = await transport.count()
    expectEqual(count, 1)
    let request = await transport.first()!
    expectEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
    expectEqual(request.httpMethod, "POST")
    expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    expectEqual(body["store"] as? Bool, false)
    expectEqual(body["model"] as? String, "gpt-test")
    expectNil(body["temperature"])
    expectNil(body["tools"])
    expectEqual(body["input"] as? String, "Только речь")
    _ = try await generate(model: "gpt-other")
    _ = try await generate("Изменённая речь")
    let finalCount = await transport.count()
    expectEqual(finalCount, 3)
    for file in try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    {
      let contents = try String(contentsOf: file, encoding: .utf8)
      expectFalse(contents.contains(key))
      let permissions =
        try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
      expectEqual(permissions?.intValue, 0o600)
    }
  }
  func testOpenAIFailuresCancellationAndModels() async throws {
    let root = try apiTemporary()
    let errorData = Data(
      #"{"error":{"code":"insufficient_quota","message":"SECRET-DO-NOT-LOG"}}"#.utf8)
    for status in [400, 401, 403, 404, 429, 302, 500] {
      let transport = StubHTTP([.init(status: status, data: errorData)])
      let client = try OpenAIClient(apiKey: "test-key-only", transport: transport)
      do {
        _ = try await client.models()
        fail("HTTP failure accepted: \(status)")
      } catch { expectFalse(error.localizedDescription.contains("SECRET")) }
      let calls = await transport.count()
      expectEqual(calls, 1)
    }
    let modelData = Data(
      #"{"data":[{"id":"gpt-test"},{"id":"gpt-audio"},{"id":"gpt-test"},{"id":"o3"},{"id":"text-embedding-3-small"}]}"#
        .utf8)
    let retry = StubHTTP([.init(status: 429, data: Data()), .init(status: 200, data: modelData)])
    let models = try await OpenAIClient(apiKey: "test-key-only", transport: retry).models()
    expectEqual(models, ["gpt-test", "o3"])
    let retryCount = await retry.count()
    expectEqual(retryCount, 2)
    for response in [
      try apiReply(status: "incomplete"), try apiReply(text: "not-json"),
      StubHTTP.Reply(
        status: 200,
        data: Data(
          #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal"}]}]}"#
            .utf8)),
    ] {
      let client = try OpenAIClient(apiKey: "test-key-only", transport: StubHTTP([response]))
      do {
        _ = try await client.generate(
          instruction: "Test", input: "Speech", schema: "{}", model: "gpt-test", directory: root)
        fail("Incomplete/invalid/refused response accepted")
      } catch { expect(error is MeetingError) }
    }
    let delayed = try OpenAIClient(
      apiKey: "test-key-only", transport: StubHTTP([apiReply()], delay: 20))
    let task = Task {
      try await delayed.generate(
        instruction: "Test", input: "Speech", schema: "{}", model: "gpt-test", directory: root)
    }
    try await Task.sleep(for: .milliseconds(40))
    task.cancel()
    do {
      _ = try await task.value
      fail("Cancelled API request completed")
    } catch { expect(error is CancellationError) }
    try expectEqual(FileManager.default.contentsOfDirectory(atPath: root.path), [])
  }
  func testOpenAIProcessorPreservesSourcesAndWorkspace() async throws {
    let root = try apiTemporary()
    let store = try SessionStore(root: root)
    var meeting = Meeting(title: "API fixture", language: "ru", screenRecorded: false)
    meeting.status = .complete
    try store.create(meeting)
    let directory = store.directory(meeting.id)
    let chunk = AudioChunk(
      id: "source", source: .system, start: 0, duration: 20, features: AudioAnalysis.features([0.1])
    )
    let result = Transcription(
      chunk: chunk,
      utterances: [
        Utterance(start: 0, end: 20, text: "Анна подготовит документ. Бюджет не утверждён.")
      ], language: "ru")
    try store.save(result, meetingID: meeting.id)
    try SessionStore.write(chunk, to: directory.appendingPathComponent("chunks/source.json"))
    var workspace = MeetingWorkspace()
    workspace.personalNotes = "PRIVATE-PERSONAL-NOTES"
    workspace.tasks = [MeetingTask(title: "Моя задача")]
    workspace.tasks[0].isComplete = true
    try store.saveWorkspace(workspace, id: meeting.id)
    let old = Markdown.document(
      meeting: meeting, results: [result], notes: [], report: "Предыдущий протокол")
    try store.publish(SavedProtocol(document: old, insights: MeetingInsights()), id: meeting.id)
    let beforeWorkspace = try Data(contentsOf: directory.appendingPathComponent("workspace.json"))
    let beforeSource = try Data(contentsOf: directory.appendingPathComponent("results/source.json"))
    let text =
      #"{"introduction":"Обсудили документ и бюджет.","points":[{"topic":"Бюджет","text":"Бюджет не утверждён.","ids":[1]}],"nextSteps":[{"topic":"Анна","text":"Подготовить документ.","ids":[1]}]}"#
    let transport = try StubHTTP([apiReply(text: text)])
    let missing = root.appendingPathComponent("must-not-run")
    let ai = LocalAI(
      paths: RuntimePaths(
        whisper: missing, llama: missing, speechModel: missing, textModel: missing))
    let speech = SpeechWorker(paths: ai.paths)
    let processor = MeetingProcessor(
      store: store, ai: ai, speech: speech, openAIKey: { "test-key-only" }, transport: transport)
    let job = ProcessingJob(
      id: meeting.id, grounded: true, summaryOnly: true,
      configuration: SummaryConfiguration(provider: .openAI, model: "gpt-test"))
    try await processor.process(job) { _ in }
    let saved = try store.savedProtocol(meeting.id)!
    expect(saved.document.hasSuffix(old.components(separatedBy: "## Протокол и итоги")[1]))
    expectEqual(saved.insights.brief?.generation?.configuration.model, "gpt-test")
    try expectEqual(
      Data(contentsOf: directory.appendingPathComponent("results/source.json")), beforeSource)
    try expectEqual(
      Data(contentsOf: directory.appendingPathComponent("workspace.json")), beforeWorkspace)
    let request = await transport.first()!
    expectFalse(
      String(decoding: request.httpBody!, as: UTF8.self).contains("PRIVATE-PERSONAL-NOTES"))
    let previous = try Data(contentsOf: directory.appendingPathComponent("protocol.json"))
    var failingJob = job
    failingJob.summaryConfiguration?.model = "gpt-unavailable"
    do {
      try await processor.process(failingJob) { _ in }
      fail("Offline job succeeded")
    } catch { expect(error is MeetingError) }
    try expectEqual(Data(contentsOf: directory.appendingPathComponent("protocol.json")), previous)
    var full = job
    full.summaryOnly = nil
    try await processor.process(full) { _ in }
    try expectEqual(store.savedProtocol(meeting.id)?.insights.brief?.nextSteps.count, 1)
    await speech.shutdown()
  }
}
