import Foundation

public struct SessionStore: Sendable {
  public let root: URL
  public init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
  public func directory(_ id: UUID) -> URL {
    root.appendingPathComponent(id.uuidString, isDirectory: true)
  }
  public func create(_ meeting: Meeting) throws {
    let dir = directory(meeting.id)
    for name in ["chunks", "results", "notes", "video", "drafts"] {
      try FileManager.default.createDirectory(
        at: dir.appendingPathComponent(name), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    try save(meeting)
  }
  public func save(_ meeting: Meeting) throws {
    try Self.write(meeting, to: directory(meeting.id).appendingPathComponent("meeting.json"))
  }
  /// Moves the complete session to Finder's Trash, keeping deletion recoverable.
  @discardableResult
  public func trash(_ id: UUID) throws -> URL? {
    var destination: NSURL?
    try FileManager.default.trashItem(at: directory(id), resultingItemURL: &destination)
    return destination as URL?
  }
  public func list() throws -> [Meeting] {
    try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { UUID(uuidString: $0.lastPathComponent) != nil }
      .map { folder in
        do {
          let meeting = try Self.read(
            Meeting.self, from: folder.appendingPathComponent("meeting.json"))
          guard meeting.id == UUID(uuidString: folder.lastPathComponent),
            meeting.duration.isFinite, meeting.duration >= 0
          else {
            throw MeetingError.message("Сведения не соответствуют папке встречи.")
          }
          return meeting
        } catch {
          var recovered = Meeting(title: "Повреждены сведения о встрече")
          recovered.id = UUID(uuidString: folder.lastPathComponent) ?? recovered.id
          recovered.status = .interrupted
          recovered.issues = [
            "Не удалось прочитать meeting.json. Исходный файл сохранён; откройте папку встречи для проверки."
          ]
          return recovered
        }
      }
      .sorted { $0.startedAt > $1.startedAt }
  }
  public func chunks(_ id: UUID) throws -> [AudioChunk] {
    let chunks = try objects(AudioChunk.self, folder: "chunks", id: id)
    for chunk in chunks { try chunk.validate() }
    guard Set(chunks.map(\.id)).count == chunks.count else {
      throw MeetingError.message(
        "Повторяющиеся идентификаторы аудиофрагментов. Проверьте папку встречи.")
    }
    return chunks.sorted { $0.start < $1.start }
  }
  public func results(_ id: UUID) throws -> [Transcription] {
    let values = try objects(Transcription.self, folder: "results", id: id)
    for result in values { try result.chunk.validate() }
    return values.sorted {
      $0.chunk.start < $1.chunk.start
    }
  }
  /// Preserve malformed or orphaned results for inspection; their WAV is queued again.
  public func recoverResults(_ id: UUID) throws -> Int {
    let validChunks = Dictionary(uniqueKeysWithValues: try chunks(id).map { ($0.id, $0) })
    let folder = directory(id).appendingPathComponent("results")
    var recovered = 0
    for file in try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: nil)
    where file.pathExtension == "json" {
      do {
        let result = try Self.read(Transcription.self, from: file)
        try result.chunk.validate()
        guard let chunk = validChunks[result.id],
          file.deletingPathExtension().lastPathComponent == result.id,
          chunk.source == result.chunk.source, chunk.start == result.chunk.start,
          chunk.duration == result.chunk.duration,
          result.utterances.allSatisfy({
            $0.start.isFinite && $0.end.isFinite && $0.start >= chunk.start && $0.end >= $0.start
              && $0.end <= chunk.start + chunk.duration + 0.01
          })
        else { throw MeetingError.message("Повреждён результат распознавания.") }
      } catch {
        try FileManager.default.moveItem(
          at: file,
          to: file.appendingPathExtension("invalid-\(UUID().uuidString)"))
        recovered += 1
      }
    }
    return recovered
  }
  public func notes(_ id: UUID) throws -> [TimelineNote] {
    try objects(TimelineNote.self, folder: "notes", id: id).sorted { $0.time < $1.time }
  }
  public func save(_ result: Transcription, meetingID: UUID) throws {
    try result.chunk.validate()
    try Self.write(
      result, to: directory(meetingID).appendingPathComponent("results/\(result.id).json"))
  }
  public func save(_ note: TimelineNote, meetingID: UUID) throws {
    try Self.write(note, to: directory(meetingID).appendingPathComponent("notes/\(note.id).json"))
  }
  private func objects<T: Decodable>(_ type: T.Type, folder: String, id: UUID) throws -> [T] {
    try FileManager.default.contentsOfDirectory(
      at: directory(id).appendingPathComponent(folder), includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".open.json") }
    .map { try Self.read(type, from: $0) }
  }
  public static func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try writePrivate(encoder.encode(value), to: url)
  }
  public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(contentsOf: url))
  }
  public func writeMarkdown(_ text: String, id: UUID) throws -> URL {
    let url = directory(id).appendingPathComponent("meeting.md")
    try Self.writePrivate(Data(text.utf8), to: url)
    return url
  }
  public static func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
