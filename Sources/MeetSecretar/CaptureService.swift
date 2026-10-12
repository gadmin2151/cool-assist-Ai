import AVFoundation
import CoreMedia
import MeetingCore
import ScreenCaptureKit
import Vision

final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate,
  AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable
{
  private let queue = DispatchQueue(label: "meet.capture", qos: .userInitiated)
  private let sessionQueue = DispatchQueue(label: "meet.microphone.session", qos: .userInitiated)
  private let ocrQueue = DispatchQueue(label: "meet.ocr", qos: .utility)
  private let ocrGate = DispatchSemaphore(value: 1)
  private var stream: SCStream?
  private var microphoneSession: AVCaptureSession?
  private var microphoneOutput: AVCaptureAudioDataOutput?
  private var microphoneSessionID: UUID?
  private var microphoneObservers: [NSObjectProtocol] = []
  private var spools: [AudioSource: AudioSpool] = [:]
  private var converters: [AudioSource: AVAudioConverter] = [:]
  private var video: VideoSegments?
  private var hostOrigin: Double = 0
  private var lastOCR: Double = -30
  private var lastScreenText = ""
  private var paused = false
  private var failed = false
  private var receivedSources: Set<AudioSource> = []
  private var lastMeter: [AudioSource: Double] = [:]
  var onLevel: ((AudioSource, Double) -> Void)?
  var onChunk: ((AudioChunk) -> Void)?
  var onNote: ((TimelineNote) -> Void)?
  var onError: ((String) -> Void)?

  func start(
    directory: URL, displayID: CGDirectDisplayID?, microphone: String?, recordScreen: Bool,
    useOCR: Bool, captureSystemAudio: Bool = true
  ) async throws {
    guard stream == nil, microphoneSession == nil else {
      throw MeetingError.message("Запись уже запущена.")
    }
    let devices = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
    ).devices
    if let microphone,
      !devices.contains(where: { $0.uniqueID == microphone })
    {
      throw MeetingError.message(
        "Выбранный микрофон отключён. Выберите доступный микрофон в настройках.")
    }
    paused = false
    failed = false
    receivedSources.removeAll()
    converters.removeAll()
    spools.removeAll()
    lastMeter.removeAll()
    lastScreenText = ""
    video = nil
    hostOrigin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
    let sources: [AudioSource] = captureSystemAudio ? AudioSource.allCases : [.microphone]
    for source in sources {
      let spool = AudioSpool(
        folder: directory.appendingPathComponent("chunks"), source: source,
        minimumDuration: 3, maximumDuration: 8)
      spool.onChunk = { [weak self] in self?.onChunk?($0) }
      spools[source] = spool
    }
    if !captureSystemAudio {
      lastOCR = .infinity
      try await startMicrophone(deviceID: microphone)
      return
    }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard
      let display = displayID == nil
        ? (content.displays.first(where: { $0.displayID == CGMainDisplayID() })
          ?? content.displays.first)
        : content.displays.first(where: { $0.displayID == displayID })
    else {
      throw MeetingError.message(
        "Выбранный экран недоступен. Обновите список экранов в настройках.")
    }
    let ownApps = content.applications.filter {
      $0.processID == ProcessInfo.processInfo.processIdentifier
    }
    let filter = SCContentFilter(
      display: display, excludingApplications: ownApps, exceptingWindows: [])
    let config = SCStreamConfiguration()
    config.width = min(1600, display.width)
    config.height =
      Int(Double(display.height) * Double(config.width) / Double(display.width)) / 2 * 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: recordScreen ? 8 : 1)
    config.queueDepth = 5
    config.showsCursor = true
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = true
    config.sampleRate = 48000
    config.channelCount = 2
    config.captureMicrophone = true
    if let microphone { config.microphoneCaptureDeviceID = microphone }
    if recordScreen {
      video = VideoSegments(
        folder: directory.appendingPathComponent("video"), width: config.width,
        height: config.height, onError: { [weak self] in self?.onError?($0) })
    }
    lastOCR = useOCR ? -30 : .infinity
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    self.stream = stream
    try await stream.startCapture()
  }

  private func startMicrophone(deviceID: String?) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      sessionQueue.async {
        do {
          let device: AVCaptureDevice?
          if let deviceID {
            device = AVCaptureDevice.DiscoverySession(
              deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
            ).devices.first { $0.uniqueID == deviceID }
          } else {
            device = AVCaptureDevice.default(for: .audio)
          }
          guard let device else {
            throw MeetingError.message(
              "Микрофон недоступен. Подключите микрофон и повторите запись.")
          }
          let session = AVCaptureSession()
          let input = try AVCaptureDeviceInput(device: device)
          let output = AVCaptureAudioDataOutput()
          guard session.canAddInput(input) else {
            throw MeetingError.message("Не удалось настроить запись выбранного микрофона.")
          }
          session.beginConfiguration()
          session.addInput(input)
          guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MeetingError.message("Не удалось настроить аудиопоток микрофона.")
          }
          session.addOutput(output)
          session.commitConfiguration()
          output.setSampleBufferDelegate(self, queue: self.queue)
          let sessionID = UUID()
          self.queue.sync {
            self.microphoneSession = session
            self.microphoneOutput = output
            self.microphoneSessionID = sessionID
          }
          self.observeMicrophone(session, sessionID: sessionID)
          session.startRunning()
          // Drain errors posted during startRunning before reporting a successful start.
          guard session.isRunning, self.queue.sync(execute: { !self.failed }) else {
            throw MeetingError.message(
              "Не удалось включить микрофон. Проверьте доступ к микрофону в настройках macOS.")
          }
          continuation.resume()
        } catch {
          self.removeMicrophoneObservers()
          self.microphoneOutput?.setSampleBufferDelegate(nil, queue: nil)
          self.microphoneSession?.stopRunning()
          self.queue.sync {
            self.microphoneOutput = nil
            self.microphoneSession = nil
            self.microphoneSessionID = nil
          }
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func observeMicrophone(_ session: AVCaptureSession, sessionID: UUID) {
    let center = NotificationCenter.default
    microphoneObservers = [
      center.addObserver(
        forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
      ) {
        [weak self] notification in
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        self?.microphoneFailed(
          error.map { "Запись микрофона остановлена: \($0.localizedDescription)" }
            ?? "Запись микрофона остановлена из-за ошибки аудиоустройства.", sessionID: sessionID)
      },
      center.addObserver(
        forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
      ) {
        [weak self] _ in
        self?.microphoneFailed(
          "Доступ к микрофону прерван. Записанные фрагменты сохранены.", sessionID: sessionID)
      },
    ]
  }

  private func microphoneFailed(_ message: String, sessionID: UUID) {
    queue.async { [weak self] in
      guard let self, self.microphoneSessionID == sessionID, !self.failed else { return }
      self.failed = true
      self.onError?(message)
    }
  }

  private func removeMicrophoneObservers() {
    for observer in microphoneObservers { NotificationCenter.default.removeObserver(observer) }
    microphoneObservers.removeAll()
  }

  func setPaused(_ value: Bool) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        do {
          self.paused = value
          if value {
            for spool in self.spools.values { try spool.finish() }
            self.video?.finishSegment()
          }
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  func stop() async throws -> Set<AudioSource> {
    var stopError: Error?
    do { try await stream?.stopCapture() } catch { stopError = error }
    await withCheckedContinuation { continuation in
      sessionQueue.async {
        self.removeMicrophoneObservers()
        self.microphoneSession?.stopRunning()
        self.microphoneOutput?.setSampleBufferDelegate(nil, queue: nil)
        continuation.resume()
      }
    }
    let outcome = await withCheckedContinuation {
      (continuation: CheckedContinuation<(Set<AudioSource>, Error?), Never>) in
      queue.async {
        self.paused = true
        var failure: Error?
        for spool in self.spools.values {
          do { try spool.finish() } catch { failure = failure ?? error }
        }
        self.video?.finishSegment()
        self.microphoneSession = nil
        self.microphoneOutput = nil
        self.microphoneSessionID = nil
        continuation.resume(returning: (self.receivedSources, failure))
      }
    }
    await withCheckedContinuation { continuation in ocrQueue.async { continuation.resume() } }
    await video?.waitForCompletion()
    stream = nil
    if let stopError { throw stopError }
    if let error = outcome.1 { throw error }
    return outcome.0
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    onError?("Захват остановлен: \(error.localizedDescription)")
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard sampleBuffer.isValid, !paused, !failed, let session = microphoneSession else { return }
    let timestamp =
      session.synchronizationClock.map {
        CMSyncConvertTime(
          sampleBuffer.presentationTimeStamp, from: $0, to: CMClockGetHostTimeClock())
      } ?? CMClockGetTime(CMClockGetHostTimeClock())
    guard timestamp.seconds.isFinite else { return }
    let time = max(0, timestamp.seconds - hostOrigin)
    do {
      try appendAudio(sampleBuffer, source: .microphone, time: time)
    } catch {
      failed = true
      onError?(error.localizedDescription)
    }
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard sampleBuffer.isValid, !paused, !failed else { return }
    let time = max(0, sampleBuffer.presentationTimeStamp.seconds - hostOrigin)
    do {
      switch type {
      case .audio, .microphone:
        let source: AudioSource = type == .audio ? .system : .microphone
        try appendAudio(sampleBuffer, source: source, time: time)
      case .screen:
        guard
          let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete
        else { return }
        try video?.append(sampleBuffer, time: time)
        if time - lastOCR >= 20, let buffer = sampleBuffer.imageBuffer,
          ocrGate.wait(timeout: .now()) == .success
        {
          lastOCR = time
          ocrQueue.async { [weak self] in
            guard let self else { return }
            defer { self.ocrGate.signal() }
            do {
              let request = VNRecognizeTextRequest()
              request.recognitionLevel = .accurate
              request.automaticallyDetectsLanguage = true
              request.usesLanguageCorrection = true
              try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
              let text = (request.results ?? []).compactMap { $0.topCandidates(1).first }.filter {
                $0.confidence > 0.55
              }.map(\.string).joined(separator: "\n")
              if !text.isEmpty, text != self.lastScreenText {
                self.lastScreenText = text
                self.onNote?(TimelineNote(time: time, kind: "screen", text: text))
              }
            } catch {
              self.onNote?(
                TimelineNote(time: time, kind: "OCR", text: "Не удалось распознать этот кадр."))
            }
          }
        }
      @unknown default: break
      }
    } catch {
      failed = true
      onError?(error.localizedDescription)
    }
  }

  private func appendAudio(_ sample: CMSampleBuffer, source: AudioSource, time: Double) throws {
    let samples = try normalized(sample, source: source)
    guard !samples.isEmpty else { return }
    receivedSources.insert(source)
    try spools[source]?.append(samples, at: time)
    let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
    if time - (lastMeter[source] ?? -1) >= 0.2 {
      lastMeter[source] = time
      onLevel?(source, min(1, rms * 8))
    }
  }

  private func normalized(_ sample: CMSampleBuffer, source: AudioSource) throws -> [Float] {
    guard let description = sample.formatDescription,
      let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
      let format = AVAudioFormat(streamDescription: basic),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples))
    else {
      throw MeetingError.message("Не поддерживается формат аудиоустройства.")
    }
    buffer.frameLength = buffer.frameCapacity
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sample, at: 0, frameCount: Int32(sample.numSamples), into: buffer.mutableAudioBufferList)
    guard status == noErr else {
      throw MeetingError.message("Ошибка чтения аудиопотока: \(status).")
    }
    guard
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
    else { throw MeetingError.message("Ошибка настройки PCM.") }
    if converters[source]?.inputFormat != format {
      converters[source] = AVAudioConverter(from: format, to: target)
    }
    guard let converter = converters[source],
      let output = AVAudioPCMBuffer(
        pcmFormat: target,
        frameCapacity: AVAudioFrameCount(
          ceil(Double(sample.numSamples) * 16000 / format.sampleRate)) + 64)
    else {
      throw MeetingError.message("Не удалось преобразовать аудио в 16 кГц.")
    }
    var delivered = false
    var conversionError: NSError?
    let result = converter.convert(to: output, error: &conversionError) { _, status in
      if delivered {
        status.pointee = .noDataNow
        return nil
      }
      delivered = true
      status.pointee = .haveData
      return buffer
    }
    if let conversionError { throw conversionError }
    guard result != .error, let data = output.floatChannelData?[0] else {
      throw MeetingError.message("Ошибка преобразования аудио.")
    }
    return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
  }
}

private final class VideoSegments {
  private let folder: URL
  private let width: Int
  private let height: Int
  private let onError: (String) -> Void
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var start: Double = 0
  private let group = DispatchGroup()
  init(folder: URL, width: Int, height: Int, onError: @escaping (String) -> Void) {
    self.folder = folder
    self.width = width
    self.height = height
    self.onError = onError
  }
  func append(_ sample: CMSampleBuffer, time: Double) throws {
    if writer != nil && time - start >= 300 { finishSegment() }
    if writer == nil {
      let url = folder.appendingPathComponent(
        String(format: "%06d-%@.mov", Int(time), UUID().uuidString.prefix(8) as CVarArg))
      let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
      writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
          AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_200_000],
        ])
      input.expectsMediaDataInRealTime = true
      guard writer.canAdd(input) else {
        throw MeetingError.message("Не удалось настроить запись видео.")
      }
      writer.add(input)
      guard writer.startWriting() else {
        throw writer.error ?? MeetingError.message("Не удалось начать запись видео.")
      }
      writer.startSession(atSourceTime: sample.presentationTimeStamp)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      self.writer = writer
      self.input = input
      start = time
    }
    if let input, input.isReadyForMoreMediaData, !input.append(sample) {
      throw writer?.error ?? MeetingError.message("Ошибка записи видео.")
    }
  }
  func finishSegment() {
    guard let writer else { return }
    input?.markAsFinished()
    self.writer = nil
    input = nil
    group.enter()
    writer.finishWriting { [group, onError] in
      if writer.status != .completed {
        onError("Видеофрагмент не завершён. Аудио сохраняется отдельно.")
      }
      group.leave()
    }
  }
  func waitForCompletion() async {
    await withCheckedContinuation { continuation in
      group.notify(queue: .global()) { continuation.resume() }
    }
  }
}
