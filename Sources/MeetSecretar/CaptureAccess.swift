import AVFoundation
import MeetingCore
import ScreenCaptureKit

enum ScreenAccessState: Equatable {
  case notChecked
  case checking
  case available
  case denied
  case unavailable(String)
  case restartRequired

  var label: String {
    switch self {
    case .notChecked: return "Не проверен"
    case .checking: return "Проверяю…"
    case .available: return "Разрешён"
    case .denied: return "Нужен доступ"
    case .unavailable: return "Не удалось проверить"
    case .restartRequired: return "Нужен перезапуск"
    }
  }

  var detail: String? {
    switch self {
    case .notChecked:
      return "Нажмите «Проверить доступ», чтобы проверить захват для этой версии приложения."
    case .denied:
      return
        "macOS отклонила захват для этого приложения. Если переключатель уже включён, выключите и включите его для Cool Assist Ai, затем перезапустите приложение."
    case .unavailable(let message):
      return
        "Не удалось проверить захват: \(message). Повторите проверку; это не означает отказ в разрешении."
    case .restartRequired:
      return
        "Разрешение включено, но macOS пока отклоняет захват. Перезапустите Cool Assist Ai и повторите проверку."
    case .checking, .available: return nil
    }
  }

  static func failure(_ error: Error, preflightAllowed: Bool) -> Self {
    let error = error as NSError
    if error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    {
      return preflightAllowed ? .restartRequired : .denied
    }
    return .unavailable("\(error.localizedDescription) (\(error.domain), \(error.code))")
  }
}

@MainActor protocol ScreenAccessChecking {
  func preflightAllowed() -> Bool
  func displays() async throws -> [SCDisplay]
}

@MainActor struct SystemScreenAccessChecker: ScreenAccessChecking {
  func preflightAllowed() -> Bool { CGPreflightScreenCaptureAccess() }
  func displays() async throws -> [SCDisplay] {
    try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
  }
}

protocol MeetingCapture: AnyObject {
  var onLevel: ((AudioSource, Double) -> Void)? { get set }
  var onChunk: ((AudioChunk) -> Void)? { get set }
  var onNote: ((TimelineNote) -> Void)? { get set }
  var onError: ((String) -> Void)? { get set }
  func start(
    directory: URL, displayID: CGDirectDisplayID?, microphone: String?, recordScreen: Bool,
    useOCR: Bool, captureSystemAudio: Bool) async throws
  func setPaused(_ paused: Bool) async throws
  func stop() async throws -> Set<AudioSource>
}

extension CaptureService: MeetingCapture {}

@MainActor protocol CaptureAuthorization {
  func authorize(requiresScreen: Bool) async throws
}

@MainActor struct SystemCaptureAuthorization: CaptureAuthorization {
  var microphoneAccess: () async -> Bool = {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
      ? true : await AVCaptureDevice.requestAccess(for: .audio)
  }
  var screenAccess: () async throws -> Void = {
    // A checked toggle can belong to an older local signature. Validate actual SC access.
    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  }

  func authorize(requiresScreen: Bool) async throws {
    guard await microphoneAccess() else {
      throw MeetingError.message("Разрешите доступ к микрофону в настройках macOS.")
    }
    if requiresScreen { try await screenAccess() }
  }
}
