import Foundation

/// One instance per source, owned by the capture serial queue. PCM hits disk immediately.
public final class AudioSpool {
  private let folder: URL
  private let source: AudioSource
  private let minimumDuration: Double
  private let maximumDuration: Double
  private var handle: FileHandle?
  private var open: OpenChunk?
  private var samples: [Float] = []
  private var lastSync = Date.distantPast
  public var onChunk: ((AudioChunk) -> Void)?

  private struct OpenChunk: Codable {
    var id: String
    var source: AudioSource
    var start: Double
  }
  public init(
    folder: URL, source: AudioSource, minimumDuration: Double = 15, maximumDuration: Double = 24
  ) {
    precondition(
      minimumDuration > 0 && maximumDuration >= minimumDuration && maximumDuration <= 120)
    self.folder = folder
    self.source = source
    self.minimumDuration = minimumDuration
    self.maximumDuration = maximumDuration
  }

  public func append(_ input: [Float], at time: Double) throws {
    guard !input.isEmpty else { return }
    guard time.isFinite, time >= 0 else {
      throw MeetingError.message("Некорректная временная отметка аудиофрагмента.")
    }
    if let open, abs(time - (open.start + Double(samples.count) / 16000)) > 0.5 { try finish() }
    let maximumSamples = max(1, Int(maximumDuration * Double(AudioAnalysis.sampleRate)))
    var offset = 0
    while offset < input.count {
      if open == nil {
        let chunk = OpenChunk(
          id: "\(source.rawValue)-\(UUID().uuidString)", source: source,
          start: time + Double(offset) / Double(AudioAnalysis.sampleRate))
        try SessionStore.write(chunk, to: folder.appendingPathComponent("\(chunk.id).open.json"))
        let url = folder.appendingPathComponent("\(chunk.id).pcm")
        guard
          FileManager.default.createFile(
            atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw MeetingError.message("Не удалось создать аудиофрагмент.") }
        handle = try FileHandle(forWritingTo: url)
        open = chunk
      }
      // Capture callbacks are usually small, but device changes and recovered input
      // may deliver a large buffer. Keep every sample and enforce the ASR size bound.
      let end = min(input.count, offset + maximumSamples - samples.count)
      let slice = Array(input[offset..<end])
      try handle?.write(contentsOf: AudioAnalysis.pcm16(slice))
      samples.append(contentsOf: slice)
      offset = end
      if Date().timeIntervalSince(lastSync) >= 2 {
        try handle?.synchronize()
        lastSync = Date()
      }
      let duration = Double(samples.count) / Double(AudioAnalysis.sampleRate)
      let tailEnergy =
        samples.suffix(4800).reduce(0.0) { $0 + Double($1 * $1) }
        / Double(min(samples.count, 4800))
      if samples.count >= maximumSamples || (duration >= minimumDuration && tailEnergy < 0.00001) {
        try finish()
      }
    }
  }

  public func finish() throws {
    guard let open else { return }
    try handle?.synchronize()
    try handle?.close()
    handle = nil
    let chunk = try Self.commit(open, folder: folder)
    self.open = nil
    samples.removeAll(keepingCapacity: true)
    if let chunk { onChunk?(chunk) }
  }

  private static func commit(_ open: OpenChunk, folder: URL) throws -> AudioChunk? {
    guard open.id == URL(fileURLWithPath: open.id).lastPathComponent,
      !open.id.contains(".."), open.start.isFinite, open.start >= 0
    else { throw MeetingError.message("Некорректные сведения о незавершённом аудиофрагменте.") }
    let pcmURL = folder.appendingPathComponent("\(open.id).pcm")
    // A crash can occur between the atomic metadata write and PCM file creation.
    guard FileManager.default.fileExists(atPath: pcmURL.path) else {
      try FileManager.default.removeItem(at: folder.appendingPathComponent("\(open.id).open.json"))
      return nil
    }
    let pcm = try Data(contentsOf: pcmURL)
    var chunk: AudioChunk?
    if pcm.count >= 2 {
      let validPCM = pcm.prefix(pcm.count - pcm.count % 2)
      let samples = AudioAnalysis.floats(Data(validPCM))
      let value = AudioChunk(
        id: open.id, source: open.source, start: open.start,
        duration: Double(samples.count) / 16000, features: AudioAnalysis.features(samples))
      try AudioAnalysis.wave(pcm: Data(validPCM)).write(
        to: folder.appendingPathComponent("\(open.id).wav"), options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: folder.appendingPathComponent("\(open.id).wav").path)
      try SessionStore.write(value, to: folder.appendingPathComponent("\(open.id).json"))
      chunk = value
    }
    try FileManager.default.removeItem(at: folder.appendingPathComponent("\(open.id).open.json"))
    try FileManager.default.removeItem(at: pcmURL)
    return chunk
  }

  public static func recover(folder: URL) throws -> Int {
    let openFiles = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasSuffix(".open.json") }
    var count = 0
    for url in openFiles {
      let open = try SessionStore.read(OpenChunk.self, from: url)
      if try commit(open, folder: folder) != nil { count += 1 }
    }
    return count
  }

  deinit { try? handle?.close() }
}
