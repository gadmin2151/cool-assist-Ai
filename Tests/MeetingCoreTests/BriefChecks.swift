import Foundation
import MeetingCore

extension MeetingCoreChecks {
  func testBriefCompatibilityAndDocumentPreservation() throws {
    let source = SourceExcerpt(start: 3600, source: .system, text: "Бюджет не утверждён.")
    let point = BriefPoint(topic: "Бюджет", text: "Бюджет не утверждён.", sources: [source])
    let brief = MeetingBrief(introduction: "Обсудили бюджет.", points: [point], nextSteps: [])
    var meeting = Meeting(title: "Тест * Markdown")
    meeting.status = .complete
    let original =
      "# Тест\n\n## Протокол и итоги\n\nСтарый протокол.\n\n## Полная расшифровка\n\nИсходная речь 🗣️\n"
    let updated = Markdown.replacingBrief(in: original, with: brief, meeting: meeting)
    expect(updated.contains("Бюджет не утверждён"))
    expect(
      updated.hasSuffix(
        "## Протокол и итоги\n\nСтарый протокол.\n\n## Полная расшифровка\n\nИсходная речь 🗣️\n"))
    expectEqual(Markdown.replacingBrief(in: updated, with: brief, meeting: meeting), updated)
    expectFalse(brief.markdown(for: meeting).contains("Ближайшие действия"))
    expect(brief.markdown(for: meeting).contains("\\*"))
    let old = Data(#"{"summary":[],"decisions":[],"actions":[],"questions":[],"topics":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(MeetingInsights.self, from: old)
    expectNil(decoded.brief)
    let job = ProcessingJob(id: meeting.id, grounded: true)
    let oldJob = try JSONDecoder().decode(ProcessingJob.self, from: JSONEncoder().encode(job))
    expectNil(oldJob.summaryOnly)
  }

  func testBriefValidationAndLongMeeting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MeetProtocol-BriefChecks-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = root.appendingPathComponent("model")
    let script = #"""
      #!/usr/bin/python3
      import json,sys,re,pathlib
      prompt=pathlib.Path(sys.argv[sys.argv.index('-f')+1]).read_text()
      source=prompt.split('ДАННЫЕ ВСТРЕЧИ:\n',1)[1].split('<|im_end|>',1)[0]
      ids=[int(v) for v in re.findall(r'\[(\d+) ·',source)]
      if not ids:
          for values in re.findall(r'"ids"\s*:\s*\[([^]]+)\]',source):
              ids.extend(int(v) for v in re.findall(r'\d+',values))
      with open('observed','a') as file:
          file.write(json.dumps({'length':len(source),'late':'Завершающее решение' in source})+'\n')
      text='Бюджет не утверждён.'
      if pathlib.Path('repeat').exists(): text='Этот вопрос подробно обсудили и пока не решили. '*3
      if pathlib.Path('bad-ids').exists(): ids=[999999]
      result={'introduction':'Обсудили бюджет.','points':[{'topic':'Бюджет','text':text,'ids':[ids[-1]]}],'nextSteps':[]}
      if pathlib.Path('large-draft').exists():
          text=' '.join(f'Параметр {i}: требуется уточнение условий поставки оборудования.' for i in range(5))
          result['points']=[{'topic':f'Тема {i}','text':text,'ids':[ids[-1]]} for i in range(4)]
      print(json.dumps(result,ensure_ascii=False));print('[end of text]')
      """#
    try Data(script.utf8).write(to: model)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: model.path)
    let ai = LocalAI(
      paths: RuntimePaths(whisper: model, llama: model, speechModel: model, textModel: model))
    let chunk = AudioChunk(
      id: "speech", source: .system, start: 0, duration: 30,
      features: AudioAnalysis.features([0.1]))
    let results = [
      Transcription(
        chunk: chunk,
        utterances: [Utterance(start: 0, end: 20, text: "Бюджет пока не утверждён.")],
        language: "ru")
    ]
    var meeting = Meeting(title: "Короткая встреча")
    let brief = try await ai.prepareBrief(results: results, meeting: meeting, directory: root) {
      _ in
    }
    expect(brief.nextSteps.isEmpty)
    expectEqual(brief.points.first?.sources.first?.text, "Бюджет пока не утверждён.")
    for marker in ["repeat", "bad-ids"] {
      try Data().write(to: root.appendingPathComponent(marker))
      meeting.title = marker
      do {
        _ = try await ai.prepareBrief(results: results, meeting: meeting, directory: root) { _ in }
        fail("Invalid résumé should be rejected: \(marker)")
      } catch { expect(error is MeetingError) }
      try FileManager.default.removeItem(at: root.appendingPathComponent(marker))
    }
    meeting.title = "Длинная встреча"
    // Bulky partial summaries require multiple reduction levels. The former hardcoded
    // 18000-character reduction budget overfilled the local model's 6000-character input.
    try Data().write(to: root.appendingPathComponent("large-draft"))
    let long = [
      Transcription(
        chunk: chunk,
        utterances: [
          Utterance(
            start: 0, end: 10800,
            text: String(
              repeating: "Длинное обсуждение бюджета 🗣️ и предложений участников. ", count: 2000)
              + "Завершающее решение: бюджет не утверждён.")
        ], language: "ru")
    ]
    let longBrief = try await ai.prepareBrief(results: long, meeting: meeting, directory: root) {
      _ in
    }
    expectFalse(longBrief.points.isEmpty)
    let observed = try String(contentsOf: root.appendingPathComponent("observed"), encoding: .utf8)
    struct Observation: Decodable {
      let length: Int
      let late: Bool
    }
    let calls = try observed.split(separator: "\n").map {
      try JSONDecoder().decode(Observation.self, from: Data($0.utf8))
    }
    expectGreater(calls.count, 6)
    // Every reduction level must obey the same local context budget as first-pass speech.
    expect(calls.allSatisfy { $0.length < 6200 })
    expect(calls.contains { $0.late })
  }
}

extension ChecksMain {
  static func briefSmoke() async throws {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--brief-smoke"), args.count > index + 3 else {
      throw MeetingError.message("Usage: --brief-smoke APP-RESOURCES MEETING-DIRECTORY OUTPUT")
    }
    let resources = URL(fileURLWithPath: args[index + 1])
    let source = URL(fileURLWithPath: args[index + 2])
    let output = URL(fileURLWithPath: args[index + 3])
    let meeting = try SessionStore.read(
      Meeting.self, from: source.appendingPathComponent("meeting.json"))
    let store = try SessionStore(root: source.deletingLastPathComponent())
    var textModel = resources.appendingPathComponent("Models/Qwen3-4B-Q4_K_M.gguf")
    if let index = args.firstIndex(of: "--text-model"), args.count > index + 1 {
      textModel = URL(fileURLWithPath: args[index + 1])
    }
    let paths = RuntimePaths(
      whisper: resources.appendingPathComponent("Runtime/whisper-cli"),
      llama: resources.appendingPathComponent("Runtime/llama/llama-completion"),
      speechModel: resources.appendingPathComponent("Models/ggml-small-q5_1.bin"),
      textModel: textModel)
    try paths.validate()
    try FileManager.default.createDirectory(
      at: output, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let results = try store.results(meeting.id)
    let started = Date()
    let brief = try await LocalAI(paths: paths).prepareBrief(
      results: results, meeting: meeting, directory: output
    ) { print($0) }
    try SessionStore.write(brief, to: output.appendingPathComponent("brief.json"))
    try SessionStore.writePrivate(
      Data(brief.markdown(for: meeting).utf8), to: output.appendingPathComponent("brief.md"))
    try SessionStore.writePrivate(
      Data(brief.markdown(for: meeting, includeSources: true).utf8),
      to: output.appendingPathComponent("brief-sources.md"))
    print(
      "PASS local résumé generated in \(Date().timeIntervalSince(started)) seconds; \(brief.points.count) topics; \(brief.nextSteps.count) next steps"
    )
  }
}
