import Foundation
import MeetingCore

extension MeetingCoreChecks {
  func testWorkspaceCompatibilityAndMerge() throws {
    let source = SourceExcerpt(start: 65.9, source: .system, text: "Анна подготовит инструкцию.")
    var insights = MeetingInsights()
    insights.actions = [source, source]
    insights.summary = [source]
    var workspace = MeetingWorkspace()
    workspace.reconcile(insights)
    expectEqual(workspace.tasks.count, 1)
    let stableID = workspace.tasks[0].id
    workspace.tasks[0].title = "Исправленная формулировка"
    workspace.tasks[0].isComplete = true
    workspace.tasks[0].assignee = "Анна"
    workspace.personalNotes = "Личная заметка"
    workspace.reconcile(insights)
    expectEqual(workspace.tasks[0].id, stableID)
    expectEqual(workspace.tasks[0].title, "Исправленная формулировка")
    expect(workspace.markdown.contains("[x]"))
    var other = MeetingWorkspace()
    other.reconcile(insights)
    expectEqual(other.tasks[0].id, stableID)
    workspace.removeTask(stableID)
    workspace.reconcile(insights)
    expect(workspace.tasks.isEmpty)
    let legacy = """
      ## Протокол
      ### Краткое содержание
      - **[00:01:05] Звук встречи:** Анна подготовит инструкцию.
      ### Поручения
      - **[00:01:05] Звук встречи:** Анна подготовит инструкцию.
      ### Открытые вопросы
      Явно не выделены в записи.
      ## Полная расшифровка
      - **[00:01:05] Звук встречи:** Это не поручение.
      """
    let parsed = MeetingInsights.legacy(markdown: legacy)
    expectEqual(parsed.actions.count, 1)
    expectEqual(parsed.actions[0].id, source.id)
    expectEqual(parsed.summary.count, 1)
    expect(parsed.questions.isEmpty)
    let old = Meeting(title: "Old")
    let encoded = try JSONEncoder().encode(old)
    var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    json.removeValue(forKey: "project")
    let decoded = try JSONDecoder().decode(
      Meeting.self, from: JSONSerialization.data(withJSONObject: json))
    expectNil(decoded.project)
    expectEqual(decoded.id, old.id)
  }
  func testInferencePriorityAndCancellation() async throws {
    actor Order {
      var values: [String] = []
      func append(_ value: String) { values.append(value) }
    }
    let gate = InferenceGate()
    let order = Order()
    try await gate.acquire(priority: .background)
    let first = Task {
      try await gate.acquire(priority: .background)
      await order.append("background")
      await gate.release()
    }
    try await Task.sleep(for: .milliseconds(30))
    let cancelled = Task {
      try await gate.acquire(priority: .live)
      await order.append("cancelled")
      await gate.release()
    }
    try await Task.sleep(for: .milliseconds(30))
    cancelled.cancel()
    do {
      try await cancelled.value
      fail("Cancelled waiter ran")
    } catch { expect(error is CancellationError) }
    let live = Task {
      try await gate.acquire(priority: .live)
      await order.append("live")
      await gate.release()
    }
    try await Task.sleep(for: .milliseconds(30))
    await gate.release()
    try await live.value
    try await first.value
    let values = await order.values
    expectEqual(values, ["live", "background"])
    try await gate.acquire(priority: .background)
    await gate.release()
  }
  func testGenerationCacheResumptionAndInvalidation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MeetProtocol-CacheChecks-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("model")
    let script = """
      #!/bin/sh
      printf 'call\\n' >> calls
      printf '%s\\n' '{"value":"готово"}' '[end of text]'
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let ai = LocalAI(
      paths: RuntimePaths(
        whisper: executable, llama: executable, speechModel: executable, textModel: executable))
    func generate(_ input: String) async throws -> String {
      try await ai.generate(
        instruction: "Test", input: input, directory: root, tokens: 100, schema: "{}")
    }
    func calls() throws -> Int {
      try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8).split(
        separator: "\n"
      ).count
    }
    let first = try await generate("one")
    let second = try await generate("one")
    expectEqual(first, second)
    try expectEqual(calls(), 1)
    _ = try await generate("changed")
    try expectEqual(calls(), 2)
    for file in try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    where file.lastPathComponent.hasPrefix("generated-") {
      try Data("broken cache".utf8).write(to: file)
    }
    _ = try await generate("one")
    try expectEqual(calls(), 3)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: executable.path)
    _ = try await generate("one")
    try expectEqual(calls(), 4)
  }
}
