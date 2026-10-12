import Foundation
import OSLog

/// Serial stdin jobs share one resident Whisper model; audio and results remain on disk.
public actor SpeechWorker {
  private let gate = InferenceGate()
  private let paths: RuntimePaths
  private var process: Process?
  private var input: FileHandle?
  private var startupDirectory: URL?
  private var startupDeadline: Date?
  private let startupTimeout: TimeInterval
  private let recognitionTimeout: TimeInterval
  public private(set) var isUsingCPU = false
  private static let logger = Logger(subsystem: "cc.idomus.meet-secretar", category: "Speech")

  private enum StartupFailure: LocalizedError {
    case timedOut
    case modelInitialization

    var errorDescription: String? {
      "Не удалось загрузить движок распознавания вовремя. Аудио сохранено; обработку можно повторить."
    }
  }

  public init(
    paths: RuntimePaths, startupTimeout: TimeInterval = 60,
    recognitionTimeout: TimeInterval = 120
  ) {
    self.paths = paths
    self.startupTimeout = startupTimeout
    self.recognitionTimeout = recognitionTimeout
  }

  public func prepare() throws {
    if process?.isRunning == true { return }
    clearStartupFiles()
    try? input?.close()
    input = nil
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CoolAssistAi-ASR-\(UUID())")
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    startupDirectory = folder
    let pipe = Pipe()
    guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      clearStartupFiles()
      throw MeetingError.message("Не удалось настроить канал движка распознавания.")
    }
    let child = Process()
    child.executableURL = paths.speechWorker
    child.arguments =
      [
        paths.speechModel.path, paths.vadModel.path, "--ready-file",
        folder.appendingPathComponent("ready.json").path,
      ] + (isUsingCPU ? ["--cpu"] : [])
    child.standardInput = pipe
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    do { try child.run() } catch {
      clearStartupFiles()
      throw error
    }
    startupDeadline = Date().addingTimeInterval(startupTimeout)
    process = child
    input = pipe.fileHandleForWriting
  }

  public func recognize(
    audio: URL, language: String, directory: URL,
    priority: InferenceGate.Priority = .background
  ) async throws -> Data {
    try await gate.acquire(priority: priority)
    do {
      let data: Data
      do {
        data = try await recognizeSerial(audio: audio, language: language, directory: directory)
      } catch is StartupFailure where !isUsingCPU {
        try Task.checkCancellation()
        // Retain CPU mode for later chunks, avoiding repeated expensive GPU starts.
        isUsingCPU = true
        Self.logger.warning(
          "Speech model GPU startup failed; switching resident recognition to CPU.")
        data = try await recognizeSerial(audio: audio, language: language, directory: directory)
      }
      await gate.release()
      return data
    } catch {
      await gate.release()
      throw error
    }
  }

  private func recognizeSerial(audio: URL, language: String, directory: URL) async throws -> Data {
    try Task.checkCancellation()
    try prepare()
    let result = directory.appendingPathComponent("live-asr-\(UUID()).json")
    defer {
      try? FileManager.default.removeItem(at: result)
      try? FileManager.default.removeItem(atPath: result.path + ".writing")
    }
    struct Request: Encodable {
      let audio: String
      let output: String
      let language: String
    }
    var data = try JSONEncoder().encode(
      Request(audio: audio.path, output: result.path, language: language))
    data.append(10)
    do {
      try await waitUntilReady()
      guard let input else {
        throw MeetingError.message("Канал распознавания закрыт. Аудио сохранено.")
      }
      try input.write(contentsOf: data)
      let deadline = Date().addingTimeInterval(recognitionTimeout)
      while !FileManager.default.fileExists(atPath: result.path) {
        try Task.checkCancellation()
        guard process?.isRunning == true else {
          throw MeetingError.message("Движок распознавания остановился. Аудио сохранено.")
        }
        guard Date() < deadline else {
          throw MeetingError.message("Распознавание превысило время ожидания. Аудио сохранено.")
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      let data = try Data(contentsOf: result)
      struct ErrorEnvelope: Decodable { let error: String? }
      if try JSONDecoder().decode(ErrorEnvelope.self, from: data).error != nil {
        throw MeetingError.message("Не удалось распознать аудиофрагмент. Исходное аудио сохранено.")
      }
      return data
    } catch {
      await shutdown()
      throw error
    }
  }

  private func waitUntilReady() async throws {
    guard let folder = startupDirectory, let deadline = startupDeadline else {
      throw MeetingError.message("Движок распознавания не запущен. Аудио сохранено.")
    }
    let ready = folder.appendingPathComponent("ready.json")
    while !FileManager.default.fileExists(atPath: ready.path) {
      try Task.checkCancellation()
      guard let child = process, child.isRunning else {
        if process?.terminationStatus == 3 { throw StartupFailure.modelInitialization }
        throw MeetingError.message("Движок распознавания остановился при запуске. Аудио сохранено.")
      }
      guard Date() < deadline else { throw StartupFailure.timedOut }
      try await Task.sleep(for: .milliseconds(50))
    }
    struct Ready: Decodable { let ready: Bool }
    guard try JSONDecoder().decode(Ready.self, from: Data(contentsOf: ready)).ready else {
      throw MeetingError.message("Движок распознавания не подтвердил готовность. Аудио сохранено.")
    }
  }

  private func clearStartupFiles() {
    // This private directory contains only a readiness marker, never meeting audio.
    if let startupDirectory { try? FileManager.default.removeItem(at: startupDirectory) }
    startupDirectory = nil
    startupDeadline = nil
  }

  public func shutdown() async {
    try? input?.close()
    input = nil
    guard let child = process else {
      clearStartupFiles()
      return
    }
    process = nil
    if child.isRunning {
      child.terminate()
      await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
      }
      if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }
    clearStartupFiles()
  }
}
