import AppKit
import MeetingCore
import SwiftUI

@main
enum Main {
  @MainActor static func main() {
    // Developer-only smoke entrypoint never requests microphone/screen permissions.
    if CommandLine.arguments.contains("--smoke-test") {
      Task {
        do {
          try await SmokeTest.run()
          exit(0)
        } catch {
          FileHandle.standardError.write(Data("Smoke failed: \(error.localizedDescription)\n".utf8))
          exit(1)
        }
      }
      RunLoop.main.run()
      return
    }
    let app = NSApplication.shared
    // A second instance must not mark the active recorder's session as interrupted.
    if let identifier = Bundle.main.bundleIdentifier,
      let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
    {
      existing.activate(options: [.activateAllWindows])
      return
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    withExtendedLifetime(delegate) {}
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var model: AppModel?
  private var window: NSWindow?
  private var widget: NSPanel?
  private var statusItem: NSStatusItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MeetSecretar/Meetings")
      #if DEBUG
        if let previewRoot =
          (Bundle.main.object(forInfoDictionaryKey: "MeetProtocolPreviewRoot") as? String)
          ?? ProcessInfo.processInfo.environment["MEET_PROTOCOL_PREVIEW_ROOT"]
        {
          root = URL(fileURLWithPath: previewRoot)
        }
      #endif
      let model = try AppModel(root: root, paths: Self.runtimePaths())
      self.model = model
      let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 900)
      let window = NSWindow(
        contentRect: NSRect(
          x: 0, y: 0, width: min(1380, available.width - 32),
          height: min(820, available.height - 40)),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.title = "Cool Assist Ai"
      window.backgroundColor = NSColor(Palette.base)
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.contentView = NSHostingView(rootView: MainView(model: model))
      window.minSize = NSSize(width: 920, height: 620)
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()
      self.window = window
      model.presentationWindow = window
      model.onOpenWorkspace = { [weak self] in self?.showMain() }
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 580, height: 128),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.contentView = NSHostingView(rootView: RecordingWidget(model: model))
      panel.level = .floating
      panel.isFloatingPanel = true
      panel.hidesOnDeactivate = false
      panel.isMovableByWindowBackground = true
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      self.widget = panel
      model.onRecordingChanged = { [weak self] recording in
        guard let self else { return }
        if recording {
          self.window?.orderOut(nil)
          if let screen = NSScreen.main {
            self.widget?.setFrameOrigin(
              NSPoint(x: screen.visibleFrame.maxX - 604, y: screen.visibleFrame.maxY - 152))
          }
          self.widget?.orderFrontRegardless()
        } else {
          self.widget?.orderOut(nil)
          self.showMain()
        }
      }
      let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      status.button?.image = CoolAssistSymbol.menuBarImage()
      status.button?.target = self
      status.button?.action = #selector(statusClicked)
      statusItem = status
      let menu = NSMenu()
      let appMenuItem = NSMenuItem()
      let appMenu = NSMenu()
      appMenu.addItem(
        withTitle: "Открыть Cool Assist Ai", action: #selector(showMain), keyEquivalent: "0"
      ).target = self
      appMenu.addItem(.separator())
      appMenu.addItem(
        withTitle: "Завершить Cool Assist Ai", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q")
      appMenuItem.submenu = appMenu
      menu.addItem(appMenuItem)
      let editItem = NSMenuItem()
      let edit = NSMenu(title: "Правка")
      for (name, action, key) in [
        ("Копировать", #selector(NSText.copy(_:)), "c"),
        ("Вставить", #selector(NSText.paste(_:)), "v"),
        ("Вырезать", #selector(NSText.cut(_:)), "x"),
        ("Выделить всё", #selector(NSText.selectAll(_:)), "a"),
      ] { edit.addItem(withTitle: name, action: action, keyEquivalent: key) }
      editItem.submenu = edit
      menu.addItem(editItem)
      NSApp.mainMenu = menu
      showMain()
    } catch {
      let alert = NSAlert()
      alert.messageText = "Не удалось открыть Cool Assist Ai"
      alert.informativeText = error.localizedDescription
      alert.runModal()
      NSApp.terminate(nil)
    }
  }
  static func runtimePaths() -> RuntimePaths {
    let resources =
      Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return RuntimePaths(
      whisper: resources.appendingPathComponent("Runtime/whisper-cli"),
      llama: resources.appendingPathComponent("Runtime/llama/llama-completion"),
      speechModel: resources.appendingPathComponent("Models/ggml-small-q5_1.bin"),
      textModel: resources.appendingPathComponent(
        "Models/Qwen3-4B-Q4_K_M.gguf"))
  }
  @objc func statusClicked() {
    if model?.isRecording == true { widget?.orderFrontRegardless() } else { showMain() }
  }
  @objc func showMain() {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    statusClicked()
    return true
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationDidBecomeActive(_ notification: Notification) { model?.refreshPermissions() }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model, model.isRecording || model.isBusy else { return .terminateNow }
    if model.canExitWithoutWaiting { return .terminateNow }
    let alert = NSAlert()
    alert.messageText =
      model.isRecording ? "Завершить запись перед выходом?" : "Прервать обработку и выйти?"
    alert.informativeText =
      "Сохранённые аудиофрагменты останутся на диске. Обработку можно продолжить при следующем запуске."
    alert.addButton(withTitle: "Продолжить работу")
    alert.addButton(withTitle: "Сохранить и выйти")
    guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
    Task {
      await model.prepareForExit()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

enum SmokeTest {
  static func run() async throws {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--smoke-test"), args.count > index + 2 else {
      throw MeetingError.message("Usage: --smoke-test WAV OUTPUT-DIRECTORY")
    }
    let audio = URL(fileURLWithPath: args[index + 1])
    let root = URL(fileURLWithPath: args[index + 2])
    let paths = await AppDelegate.runtimePaths()
    try paths.validate()
    let ai = LocalAI(paths: paths)
    let store = try SessionStore(root: root)
    var meeting = Meeting(title: "Проверка локального AI", language: "auto", screenRecorded: false)
    try store.create(meeting)
    let data = try Data(contentsOf: audio)
    guard data.count > 44 else { throw MeetingError.message("Empty WAV") }
    let samples = AudioAnalysis.floats(data.subdata(in: 44..<data.count))
    let chunk = AudioChunk(
      id: "smoke", source: .system, start: 0, duration: Double(samples.count) / 16000,
      features: AudioAnalysis.features(samples))
    let directory = store.directory(meeting.id)
    try data.write(to: directory.appendingPathComponent("chunks/smoke.wav"))
    try SessionStore.write(chunk, to: directory.appendingPathComponent("chunks/smoke.json"))
    let result = try await ai.transcribe(chunk, directory: directory, language: "auto")
    guard !result.utterances.isEmpty else { throw MeetingError.message("No speech recognized") }
    try store.save(result, meetingID: meeting.id)
    print("ASR:", result.utterances.map(\.text).joined(separator: " "))
    let report = try await ai.report(
      results: [result], notes: [], directory: directory.appendingPathComponent("drafts"),
      grounded: args.contains("--grounded")
    ) { print($0) }
    meeting.status = .complete
    meeting.duration = chunk.duration
    try store.save(meeting)
    let url = try store.writeMarkdown(
      Markdown.document(meeting: meeting, results: [result], notes: [], report: report),
      id: meeting.id)
    print("REPORT:", url.path)
  }
}
