import Foundation

import MeetingCore

extension MeetingCoreChecks {
  func testBriefEvidenceAndConservativeEchoRemoval() {
    func result(_ id: String, _ source: AudioSource, _ lines: [Utterance]) -> Transcription {
      Transcription(
        chunk: AudioChunk(
          id: id, source: source, start: 0, duration: 30,
          features: AudioAnalysis.features([0.1])),
        utterances: lines, language: "ru")
    }
    let statement = "Мы пока не утвердили бюджет проекта."
    let results = [
      result(
        "mic", .microphone,
        [
          Utterance(start: 0, end: 4, text: statement),
          Utterance(start: 5, end: 8, text: statement),
          Utterance(start: 12, end: 13, text: "Да."),
        ]),
      result(
        "sys", .system,
        [
          Utterance(start: 0.2, end: 4.2, text: statement),
          Utterance(start: 9, end: 11, text: "Анна подготовит расчёт к пятнице."),
          Utterance(start: 12.1, end: 13.1, text: "Да."),
          Utterance(start: 16, end: 20, text: "Мы утвердили бюджет проекта."),
        ]),
    ]
    let original = Markdown.transcript(results)
    let blocks = BriefBuilder.blocks(results)
    expectEqual(blocks.count, 6)
    expectEqual(blocks.filter { $0.text == statement }.count, 2)
    expectEqual(blocks.filter { $0.text == "Да." }.count, 2)
    expectEqual(blocks[2].source.source, .system)
    expectEqual(blocks[2].source.start, 9)
    expectEqual(blocks[2].source.text, "Анна подготовит расчёт к пятнице.")
    expect(blocks.allSatisfy { $0.source.text == $0.text })
    expectEqual(Markdown.transcript(results), original)
    expect(blocks.last!.text.contains("утвердили"))

    let long = result(
      "long", .system,
      [
        Utterance(
          start: 20, end: 30, text: String(repeating: "Предложение ещё обсуждается. ", count: 120))
      ])
    let pieces = BriefBuilder.blocks([long])
    expectGreater(pieces.count, 2)
    expect(pieces.allSatisfy { $0.text.count <= 1200 && $0.source.text == $0.text })
  }

  func testOversizedAudioCallbacksRemainBoundedAndLossless() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CoolAssistAi-Spool-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let spool = AudioSpool(folder: folder, source: .system, minimumDuration: 3, maximumDuration: 8)
    var chunks: [AudioChunk] = []
    spool.onChunk = { chunks.append($0) }
    let prefix = [Float](repeating: 0.2, count: 2 * 16000)
    let large = (0..<(25 * 16000)).map { Float(($0 % 200) - 100) / 500 }
    try spool.append(prefix, at: 0)
    try spool.append(large, at: 2)
    try spool.finish()
    expectEqual(chunks.map(\.start), [0, 8, 16, 24])
    expectEqual(chunks.map(\.duration), [8, 8, 8, 3])
    var recovered = Data()
    for chunk in chunks {
      try chunk.validate()
      recovered.append(
        try Data(contentsOf: folder.appendingPathComponent("\(chunk.id).wav")).dropFirst(44))
    }
    expectEqual(recovered, AudioAnalysis.pcm16(prefix + large))
    for time in [Double.nan, .infinity, -1] {
      do {
        try spool.append([0.1], at: time)
        fail("Invalid capture timestamp accepted")
      } catch { expect(error is MeetingError) }
    }
    expectEqual(chunks.count, 4)
  }

  func testRecognitionRejectsInvalidTimesAndBlankAudioMarkers() throws {
    let chunk = AudioChunk(
      id: "timing", source: .microphone, start: 100, duration: 8,
      features: AudioAnalysis.features([0.1]))
    let payload = try JSONDecoder().decode(
      WhisperResult.self,
      from: Data(
        #"""
        {"transcription":[
          {"offsets":{"from":-100,"to":1500},"text":" Бюджет не утверждён. "},
          {"offsets":{"from":1500,"to":3000},"text":"[BLANK_AUDIO]"},
          {"offsets":{"from":3000,"to":4000},"text":"[NO_SPEECH]"},
          {"offsets":{"from":4000,"to":10000},"text":"Спасибо за просмотр — это название проекта."},
          {"offsets":{"from":10000,"to":12000},"text":"Фраза за пределами аудио."}
        ]}
        """#.utf8))
    let utterances = try payload.utterances(in: chunk)
    expectEqual(utterances.count, 2)
    expectEqual(utterances[0].start, 100)
    expectEqual(utterances[0].end, 101.5)
    expectEqual(utterances[1].end, 108)
    // No phrase blacklist: a participant may actually discuss common hallucination phrases.
    expect(utterances[1].text.contains("Спасибо за просмотр"))
    let reversed = try JSONDecoder().decode(
      WhisperResult.self,
      from: Data(#"{"transcription":[{"offsets":{"from":2000,"to":1000},"text":"speech"}]}"#.utf8))
    do {
      _ = try reversed.utterances(in: chunk)
      fail("Reversed ASR timestamps accepted")
    } catch { expect(error is MeetingError) }
  }
}
