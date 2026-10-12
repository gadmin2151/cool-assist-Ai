import AVFoundation
import AppKit
import Combine
import MeetingCore
import ScreenCaptureKit
import UniformTypeIdentifiers

enum WorkspacePage { case meetings, tasks, queue }
enum SettingsSection: String, CaseIterable {
  case summary = "Резюме"
  case recording = "Запись"
  case storage = "Хранение"
}
enum MeetingTab: String, CaseIterable {
  case overview = "Резюме"
  case tasks = "Задачи"
  case transcript = "Расшифровка"
  case notes = "Заметки"
  case markdown = "Markdown"
}
struct TaskItem: Identifiable {
  var id: String { "\(meeting.id)-\(task.id)" }
  let meeting: Meeting
  let task: MeetingTask
}
struct TranscriptRow: Identifiable {
  let id: String
  let source: AudioSource
  let utterance: Utterance
}

@MainActor final class RecordingSession {
  var meeting: Meeting
  let capturesSystemAudio: Bool
  var captureError: String?
  var chunks: [AudioChunk] = []
  var results: [Transcription] = []
  var notes: [TimelineNote] = []
  var failed: Set<String> = []
  var lastDraftAt = Date.distantPast
  var lastLiveNote: Double = 0
  init(_ meeting: Meeting, capturesSystemAudio: Bool = true) {
    self.meeting = meeting
    self.capturesSystemAudio = capturesSystemAudio
  }
}

@MainActor final class AppModel: ObservableObject {
  @Published var meetings: [Meeting] = []
  @Published var selectedID: UUID?
  @Published var page = WorkspacePage.meetings
  @Published var projectFilter = ""
  @Published var title = ""
  @Published var project = ""
  @Published var language = "auto" { didSet { preferences.set(language, forKey: "language") } }
  @Published var captureSystemAudio = false {
    didSet { preferences.set(captureSystemAudio, forKey: "captureSystemAudio") }
  }
  @Published var recordScreen = true {
    didSet { preferences.set(recordScreen, forKey: "recordScreen") }
  }
  @Published var useOCR = true { didSet { preferences.set(useOCR, forKey: "useOCR") } }
  @Published var fastProcessing = true {
    didSet { preferences.set(fastProcessing, forKey: "fastTextProcessing") }
  }
  @Published var displayID: CGDirectDisplayID? {
    didSet { preferences.set(displayID, forKey: "displayID") }
  }
  @Published var microphoneID: String? {
    didSet { preferences.set(microphoneID, forKey: "microphoneID") }
  }
  @Published var displays: [SCDisplay] = []
  @Published var microphones: [AVCaptureDevice] = []
  @Published var microphoneAllowed = false
  @Published private(set) var screenAccess = ScreenAccessState.notChecked
  @Published var modelsReady = false
  @Published var isRecording = false
  @Published var isPaused = false
  @Published var isStarting = false
  @Published var isStopping = false
  @Published var isLoading = false
  @Published var elapsed: Double = 0
  @Published var micLevel: Double = 0
  @Published var systemLevel: Double = 0
  @Published var pendingCount = 0
  @Published var liveText = ""
  @Published var statusText = "Распознавание речи на этом Mac"
  @Published var error: String?
  @Published var jobs: [ProcessingJob] = []
  @Published var results: [Transcription] = []
  @Published var transcriptRows: [TranscriptRow] = []
  @Published var notes: [TimelineNote] = []
  @Published var markdown = ""
  @Published var insights = MeetingInsights()
  @Published var workspace = MeetingWorkspace()
  @Published var workspaceReadable = true
  @Published var taskItems: [TaskItem] = []
  @Published var selectedTab = MeetingTab.overview
  @Published var summaryProvider = SummaryProvider.local {
    didSet { preferences.set(summaryProvider.rawValue, forKey: "summaryProvider") }
  }
  @Published var openAIModel = "" {
    didSet { preferences.set(openAIModel, forKey: "openAIModel") }
  }
  @Published var hasOpenAIKey = false
  @Published var availableOpenAIModels: [String] = []
  @Published var checkingOpenAI = false
  @Published var openAIStatus = ""
  @Published var openAIError: String?
  @Published var showSettings = false
  @Published var settingsSection = SettingsSection.summary
  private var openAISettingsRevision = UUID()
  @Published var focusedSource: SourceExcerpt?

  let store: SessionStore
  let ai: LocalAI
  let speech: SpeechWorker
  let preferences: UserDefaults
  let authorization: any CaptureAuthorization
  let screenAccessChecker: any ScreenAccessChecking
  let captureFactory: () -> any MeetingCapture
  let keyStore: any APIKeyStore
  let httpTransport: any HTTPTransport
  var onRecordingChanged: ((Bool) -> Void)?
  var onOpenWorkspace: (() -> Void)?
  weak var presentationWindow: NSWindow?
  private var exportPanel: NSSavePanel?
  var recording: RecordingSession?
  var capture: (any MeetingCapture)?
  var liveWorker: Task<Void, Never>?
  var liveNotesTask: Task<Void, Never>?
  var timer: Timer?
  var activity: NSObjectProtocol?
  var lastMeterAt: [AudioSource: Date] = [:]
  var autoStopReason: String?
  var changingPause = false
  var isTerminating = false
  private var isRenewingPermission = false
  private var screenCheck: Task<Void, Never>?
  private var screenCheckToken = UUID()
  private var queueWorker: Task<Void, Never>?
  private var runningJobID: UUID?
  private var selectionTask: Task<Void, Never>?
  private var selectionToken = UUID()
  private var taskBoardTask: Task<Void, Never>?
  private var taskBoardToken = UUID()
  private var workspaceCache: [UUID: MeetingWorkspace] = [:]

  init(
    root: URL, paths: RuntimePaths, preferences: UserDefaults = .standard,
    prewarmSpeech: Bool = true, authorization: (any CaptureAuthorization)? = nil,
    screenAccessChecker: (any ScreenAccessChecking)? = nil,
    captureFactory: @escaping () -> any MeetingCapture = { CaptureService() },
    keyStore: any APIKeyStore = KeychainAPIKeyStore(),
    httpTransport: any HTTPTransport = OpenAITransport()
  ) throws {
    self.preferences = preferences
    self.authorization = authorization ?? SystemCaptureAuthorization()
    self.screenAccessChecker = screenAccessChecker ?? SystemScreenAccessChecker()
    self.captureFactory = captureFactory
    self.keyStore = keyStore
    self.httpTransport = httpTransport
    store = try SessionStore(root: root)
    ai = LocalAI(paths: paths)
    speech = SpeechWorker(paths: paths)
    language = preferences.string(forKey: "language") ?? "auto"
    if !["auto", "ru", "ro", "en", "uk", "de"].contains(language) { language = "auto" }
    captureSystemAudio =
      preferences.object(forKey: "captureSystemAudio") as? Bool
      ?? self.screenAccessChecker.preflightAllowed()
    recordScreen = preferences.object(forKey: "recordScreen") as? Bool ?? true
    useOCR = preferences.object(forKey: "useOCR") as? Bool ?? true
    fastProcessing = preferences.object(forKey: "fastTextProcessing") as? Bool ?? true
    displayID = (preferences.object(forKey: "displayID") as? NSNumber)?.uint32Value
    microphoneID = preferences.string(forKey: "microphoneID")
    summaryProvider =
      SummaryProvider(rawValue: preferences.string(forKey: "summaryProvider") ?? "") ?? .local
    openAIModel = preferences.string(forKey: "openAIModel") ?? ""
    hasOpenAIKey = keyStore.exists()
    let queueFile = store.root.appendingPathComponent("processing-queue.json")
    if FileManager.default.fileExists(atPath: queueFile.path) {
      do { jobs = try SessionStore.read([ProcessingJob].self, from: queueFile) } catch {
        try FileManager.default.moveItem(
          at: queueFile, to: queueFile.appendingPathExtension("invalid-\(UUID())"))
        self.error =
          "Файл очереди повреждён и сохранён отдельно. Добавьте нужные встречи в обработку снова."
      }
      var seen: Set<UUID> = []
      jobs = jobs.filter {
        seen.insert($0.id).inserted
          && FileManager.default.fileExists(atPath: store.directory($0.id).path)
      }
      for index in jobs.indices where jobs[index].state == .running {
        jobs[index].state = .queued
        jobs[index].message = "Продолжаю после перезапуска"
      }
    }
    try refreshLibrary()
    for var meeting in meetings where meeting.status == .recording || meeting.status == .processing
    {
      meeting.status = .interrupted
      meeting.issues.append("Предыдущий сеанс завершился до окончания записи или обработки.")
      try store.save(meeting)
    }
    try refreshLibrary()
    try persistQueue()
    refreshPermissions()
    do {
      try paths.validate()
      modelsReady = true
    } catch { self.error = error.localizedDescription }
    if prewarmSpeech && modelsReady {
      Task { do { try await speech.prepare() } catch { self.error = error.localizedDescription } }
    }
    refreshTaskBoard()
    launchNextJob()
  }

  var selected: Meeting? { meetings.first { $0.id == selectedID } }
  var recordingID: UUID? { recording?.meeting.id }
  var recordingTitle: String { recording?.meeting.title ?? "Встреча" }
  var recordingSystemAudio: Bool { recording?.capturesSystemAudio ?? false }
  var screenAllowed: Bool { screenAccess == .available }
  var capturePermissionsReady: Bool {
    microphoneAllowed && (!captureSystemAudio || screenAllowed)
  }
  var isBusy: Bool { isStarting || isStopping || runningJobID != nil }
  var canStart: Bool { !isStarting && !isRecording && !isStopping && !isTerminating && modelsReady }
  var canExitWithoutWaiting: Bool { !isRecording && recording == nil && runningJobID == nil }
  var projects: [String] {
    Array(Set(meetings.compactMap(\.project).filter { !$0.isEmpty })).sorted()
  }
  var openTaskCount: Int { taskItems.filter { !$0.task.isComplete }.count }
  func job(_ id: UUID?) -> ProcessingJob? { jobs.first { $0.id == id } }
  func canChangeMeeting(_ id: UUID) -> Bool { recordingID != id && runningJobID != id }
  func status(_ meeting: Meeting) -> String {
    if recordingID == meeting.id { return isPaused ? "Запись на паузе" : "Идёт запись" }
    return job(meeting.id)?.state.label ?? meeting.status.label
  }
  func refreshLibrary() throws { meetings = try store.list() }
  func refreshPermissions() {
    microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    // Preflight may stay false after access has been granted to a local build.
    // Only an actual ScreenCaptureKit result changes the verified access state.
    if captureSystemAudio && screenAccessChecker.preflightAllowed()
      && !isRecording && !isStarting && !isRenewingPermission
    {
      Task { await refreshDisplays() }
    }
    microphones =
      AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
      ).devices
  }
  func requestMicrophone() async {
    microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
    if !microphoneAllowed { openPrivacy("Privacy_Microphone") }
  }
  func requestScreen() async {
    await refreshDisplays()
    if screenAccess == .denied || screenAccess == .restartRequired {
      openPrivacy("Privacy_ScreenCapture")
    }
  }
  func renewScreenPermission() async {
    guard !isRecording && !isStarting && !isRenewingPermission else { return }
    isRenewingPermission = true
    defer {
      isRenewingPermission = false
    }
    do {
      _ = try await ProcessRunner.run(
        executable: URL(fileURLWithPath: "/usr/bin/tccutil"),
        arguments: ["reset", "ScreenCapture", "cc.idomus.meet-secretar"],
        directory: store.root, timeout: 15)
      invalidateScreenCheck()
      screenAccess = .notChecked
      error = nil
      statusText = "Запрашиваю разрешение для текущей версии приложения"
      await requestScreen()
    } catch { self.error = error.localizedDescription }
  }
  func openPrivacy(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
      NSWorkspace.shared.open(url)
    }
  }
  func refreshDisplays() async {
    if let screenCheck {
      await screenCheck.value
      return
    }
    let token = UUID()
    screenCheckToken = token
    screenAccess = .checking
    let checker = screenAccessChecker
    let check = Task { @MainActor [weak self] in
      do {
        let displays = try await checker.displays()
        guard let self, self.screenCheckToken == token else { return }
        self.displays = displays
        self.screenAccess = .available
        if let displayID = self.displayID, !displays.contains(where: { $0.displayID == displayID })
        {
          self.displayID = nil
          self.statusText = "Выбранный монитор отключён; будет использован основной экран"
        }
      } catch {
        guard let self, self.screenCheckToken == token else { return }
        self.screenAccess = .failure(error, preflightAllowed: checker.preflightAllowed())
      }
      guard let self, self.screenCheckToken == token else { return }
      self.screenCheck = nil
    }
    screenCheck = check
    await check.value
  }

  private func invalidateScreenCheck() {
    screenCheckToken = UUID()
    screenCheck?.cancel()
    screenCheck = nil
  }

  func noteScreenAuthorizationSuccess() {
    invalidateScreenCheck()
    screenAccess = .available
  }

  func noteScreenAuthorizationFailure(_ error: Error) {
    let detail = error as NSError
    if detail.domain == SCStreamErrorDomain
      && detail.code == SCStreamError.Code.userDeclined.rawValue
    {
      invalidateScreenCheck()
      screenAccess = .failure(error, preflightAllowed: screenAccessChecker.preflightAllowed())
    }
  }

  func select(_ meeting: Meeting?) {
    // Repeated clicks must not clear the open tab or restart a pending load.
    if let meeting, meeting.id == selectedID, page == .meetings { return }
    selectionTask?.cancel()
    selectionToken = UUID()
    selectedID = meeting?.id
    page = .meetings
    selectedTab = .overview
    focusedSource = nil
    error = nil
    results = []
    transcriptRows = []
    notes = []
    markdown = ""
    insights = MeetingInsights()
    workspace = MeetingWorkspace()
    workspaceReadable = true
    guard let meeting else {
      isLoading = false
      return
    }
    if let recording, recording.meeting.id == meeting.id {
      isLoading = false
      results = recording.results
      notes = recording.notes
      rebuildTranscript()
      loadWorkspace(meeting.id)
      return
    }
    reloadSelected()
  }
  func reloadSelected() {
    guard let id = selectedID, id != recordingID else { return }
    selectionTask?.cancel()
    let token = UUID()
    selectionToken = token
    isLoading = true
    let store = store
    selectionTask = Task { [weak self] in
      let snapshot = await Task.detached(priority: .utility) {
        MeetingSnapshot.load(store: store, id: id)
      }.value
      guard let self, !Task.isCancelled, self.selectedID == id, self.selectionToken == token else {
        return
      }
      self.results = snapshot.results
      self.notes = snapshot.notes
      self.markdown = snapshot.saved?.document ?? ""
      self.insights = snapshot.saved?.insights ?? MeetingInsights()
      self.workspaceReadable = snapshot.workspace != nil
      if var value = self.workspaceCache[id] ?? snapshot.workspace {
        value.reconcile(self.insights)
        self.workspace = value
        self.workspaceCache[id] = value
      }
      self.rebuildTranscript()
      self.isLoading = false
      if !snapshot.errors.isEmpty { self.error = snapshot.errors.joined(separator: "\n") }
    }
  }
  func rebuildTranscript() {
    transcriptRows = results.flatMap { result in
      result.utterances.enumerated().map { index, utterance in
        TranscriptRow(
          id: "\(result.id)-\(index)", source: result.chunk.source, utterance: utterance)
      }
    }.sorted { $0.utterance.start < $1.utterance.start }
  }
  func openSource(_ source: SourceExcerpt, meeting: Meeting? = nil) {
    if let meeting, selectedID != meeting.id { select(meeting) }
    page = .meetings
    selectedTab = .transcript
    focusedSource = source
  }
  func deleteMeeting(_ meeting: Meeting) {
    guard canChangeMeeting(meeting.id) else { return }
    do {
      try store.trash(meeting.id)
      jobs.removeAll { $0.id == meeting.id }
      try persistQueue()
      workspaceCache[meeting.id] = nil
      if selectedID == meeting.id { select(nil) }
      try refreshLibrary()
      refreshTaskBoard()
      statusText = "Встреча перемещена в Корзину"
    } catch { self.error = "Не удалось удалить встречу: \(error.localizedDescription)" }
  }
  @discardableResult func rename(_ meeting: Meeting, title: String, project: String) -> Bool {
    guard canChangeMeeting(meeting.id) else { return false }
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return false }
    do {
      var value = meeting
      value.title = String(title.prefix(300))
      value.project = project.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      if let saved = try store.savedProtocol(meeting.id) {
        var document = Markdown.updatingTitle(saved.document, meeting: value)
        if let brief = saved.insights.brief {
          document = Markdown.replacingBrief(in: document, with: brief, meeting: value)
        }
        try store.publish(
          SavedProtocol(
            document: document, insights: saved.insights, generatedAt: saved.generatedAt),
          id: meeting.id)
        if selectedID == meeting.id { markdown = document }
      }
      try store.save(value)
      try refreshLibrary()
      refreshTaskBoard()
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  // A single background pipeline bounds RAM; live ASR has priority in the shared speech worker.
  func processSelected() { if let id = selectedID { enqueue(id) } }
  var summaryConfiguration: SummaryConfiguration {
    SummaryConfiguration(provider: summaryProvider, model: openAIModel)
  }
  var summaryReady: Bool {
    summaryProvider == .local || (hasOpenAIKey && (try? summaryConfiguration.validate()) != nil)
  }
  var canSummarize: Bool {
    guard let selected else { return false }
    return selected.status == .complete && !isLoading
      && results.contains(where: { !$0.utterances.isEmpty })
      && selected.id != recordingID && job(selected.id) == nil && modelsReady && summaryReady
  }
  func summarizeSelected() {
    guard canSummarize, let id = selectedID else { return }
    enqueue(id, summaryOnly: true)
  }
  func enqueue(_ id: UUID, summaryOnly: Bool = false) {
    guard id != recordingID, modelsReady else { return }
    if let index = jobs.firstIndex(where: { $0.id == id }) {
      guard jobs[index].state == .paused || jobs[index].state == .failed else { return }
      jobs[index].state = .queued
      jobs[index].message = "Ожидает обработки"
    } else {
      var job = ProcessingJob(
        id: id, grounded: fastProcessing, summaryOnly: summaryOnly,
        configuration: summaryConfiguration)
      if !summaryReady {
        job.state = .paused
        job.message = "Настройте OpenAI или выберите локальное резюме"
        error = job.message
      }
      jobs.append(job)
    }
    do {
      try persistQueue()
      error = nil
      launchNextJob()
    } catch { self.error = error.localizedDescription }
  }
  private func persistQueue() throws {
    try SessionStore.write(jobs, to: store.root.appendingPathComponent("processing-queue.json"))
  }
  func launchNextJob() {
    guard !isTerminating, modelsReady, queueWorker == nil,
      let index = jobs.firstIndex(where: { $0.state == .queued })
    else { return }
    jobs[index].state = .running
    jobs[index].message = "Подготовка материалов"
    do { try persistQueue() } catch {
      self.error = error.localizedDescription
      return
    }
    let job = jobs[index]
    runningJobID = job.id
    let keys = keyStore
    let processor = MeetingProcessor(
      store: store, ai: ai, speech: speech,
      openAIKey: { try keys.read() }, transport: httpTransport)
    liveNotesTask?.cancel()
    let notesTask = liveNotesTask
    queueWorker = Task { [weak self] in
      let owner = self
      await notesTask?.value
      do {
        try Task.checkCancellation()
        try await processor.process(job) { update in
          await owner?.processingUpdate(update, id: job.id)
        }
        self?.jobs.removeAll { $0.id == job.id }
        self?.statusText = job.summaryOnly == true ? "Резюме готово" : "Протокол готов"
      } catch is CancellationError {
        if let self,
          let index = self.jobs.firstIndex(where: { $0.id == job.id && $0.state == .running })
        {
          self.jobs[index].state = self.isTerminating ? .queued : .paused
          self.jobs[index].message = "Сохранено; можно продолжить"
        }
      } catch {
        if let self, let index = self.jobs.firstIndex(where: { $0.id == job.id }) {
          self.jobs[index].state = .failed
          self.jobs[index].message = error.localizedDescription
          self.error = error.localizedDescription
        }
      }
      guard let self else { return }
      self.queueWorker = nil
      self.runningJobID = nil
      do {
        try self.persistQueue()
        try self.refreshLibrary()
      } catch { self.error = error.localizedDescription }
      if self.selectedID == job.id { self.reloadSelected() }
      self.refreshTaskBoard()
      self.launchNextJob()
    }
  }
  private func processingUpdate(_ update: ProcessingUpdate, id: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == id && $0.state == .running }) else {
      return
    }
    jobs[index].message = update.message
    if selectedID == id, let result = update.result {
      results.removeAll { $0.id == result.id }
      results.append(result)
      rebuildTranscript()
    }
  }
  func pauseJob(_ id: UUID) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    jobs[index].state = .paused
    jobs[index].message = "Сохранено; можно продолжить"
    if runningJobID == id { queueWorker?.cancel() }
    do { try persistQueue() } catch { self.error = error.localizedDescription }
  }
  func reconfigureJob(_ id: UUID) {
    guard runningJobID != id else { return }
    guard let job = jobs.first(where: { $0.id == id }), job.state == .paused || job.state == .failed
    else { return }
    jobs.removeAll { $0.id == id }
    enqueue(id, summaryOnly: job.summaryOnly == true)
  }
  func removeJob(_ id: UUID) {
    jobs.removeAll { $0.id == id }
    if runningJobID == id { queueWorker?.cancel() }
    do { try persistQueue() } catch { self.error = error.localizedDescription }
  }
  func cancelProcessing() { if let id = selectedID { pauseJob(id) } }

  private func loadWorkspace(_ id: UUID) {
    do {
      var value = try workspaceCache[id] ?? store.workspace(id)
      value.reconcile(try store.savedProtocol(id)?.insights ?? MeetingInsights())
      workspace = value
      workspaceCache[id] = value
      workspaceReadable = true
    } catch {
      self.error = error.localizedDescription
      workspaceReadable = false
    }
  }
  @discardableResult private func modifyWorkspace(
    _ id: UUID, refreshTasks: Bool = true, change: (inout MeetingWorkspace) -> Void
  ) -> Bool {
    do {
      var value = try workspaceCache[id] ?? store.workspace(id)
      value.reconcile(try store.savedProtocol(id)?.insights ?? MeetingInsights())
      change(&value)
      try store.saveWorkspace(value, id: id)
      workspaceCache[id] = value
      if selectedID == id { workspace = value }
      if refreshTasks { refreshTaskBoard() }
      return true
    } catch {
      self.error = "Не удалось сохранить правки: \(error.localizedDescription)"
      return false
    }
  }
  @discardableResult func saveTask(_ task: MeetingTask, meetingID: UUID) -> Bool {
    guard !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return modifyWorkspace(meetingID) { value in
      if let index = value.tasks.firstIndex(where: { $0.id == task.id }) {
        value.tasks[index] = task
      } else {
        value.tasks.append(task)
      }
    }
  }
  func toggleTask(_ task: MeetingTask, meetingID: UUID) {
    var value = task
    value.isComplete.toggle()
    saveTask(value, meetingID: meetingID)
  }
  func deleteTask(_ task: MeetingTask, meetingID: UUID) {
    modifyWorkspace(meetingID) { $0.removeTask(task.id) }
  }
  @discardableResult func savePersonalNotes(_ text: String, meetingID: UUID) -> Bool {
    modifyWorkspace(meetingID, refreshTasks: false) { $0.personalNotes = text }
  }
  func refreshTaskBoard() {
    taskBoardTask?.cancel()
    let token = UUID()
    taskBoardToken = token
    let store = store
    let meetings = meetings
    let cache = workspaceCache
    taskBoardTask = Task { [weak self] in
      let result = await Task.detached(priority: .utility) { () -> ([TaskItem], [String]) in
        var items: [TaskItem] = []
        var errors: [String] = []
        for meeting in meetings {
          do {
            var value = try cache[meeting.id] ?? store.workspace(meeting.id)
            value.reconcile(try store.savedProtocol(meeting.id)?.insights ?? MeetingInsights())
            items += value.tasks.map { TaskItem(meeting: meeting, task: $0) }
          } catch { errors.append("\(meeting.title): \(error.localizedDescription)") }
        }
        return (items, errors)
      }.value
      guard let self, !Task.isCancelled, self.taskBoardToken == token else { return }
      self.taskItems = result.0
      if !result.1.isEmpty { self.error = result.1.joined(separator: "\n") }
    }
  }
  func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    statusText = "Скопировано"
  }
  @discardableResult func saveAPIKey(_ value: String) -> Bool {
    do {
      let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
      _ = try OpenAIClient(apiKey: key)
      try keyStore.save(key)
      hasOpenAIKey = true
      openAISettingsRevision = UUID()
      availableOpenAIModels = []
      openAIStatus = "Ключ сохранён в Связке ключей macOS"
      openAIError = nil
      return true
    } catch {
      openAIError = error.localizedDescription
      return false
    }
  }
  func removeAPIKey() {
    do {
      try keyStore.remove()
      for job in jobs where job.configuration.provider == .openAI { pauseJob(job.id) }
      hasOpenAIKey = false
      summaryProvider = .local
      openAISettingsRevision = UUID()
      availableOpenAIModels = []
      openAIStatus = "Ключ удалён. Выбран локальный режим."
      openAIError = nil
    } catch { openAIError = error.localizedDescription }
  }
  func checkOpenAI() async {
    guard !checkingOpenAI else { return }
    checkingOpenAI = true
    openAIError = nil
    openAIStatus = "Проверяю ключ и получаю список моделей…"
    let revision = openAISettingsRevision
    defer { checkingOpenAI = false }
    do {
      let models = try await OpenAIClient(apiKey: keyStore.read(), transport: httpTransport)
        .models()
      guard revision == openAISettingsRevision else { return }
      availableOpenAIModels = models
      openAIStatus =
        models.isEmpty
        ? "Ключ принят. Укажите ID доступной текстовой модели вручную."
        : "Ключ принят · моделей в списке: \(models.count)"
    } catch {
      guard revision == openAISettingsRevision else { return }
      openAIStatus = ""
      openAIError = error.localizedDescription
    }
  }
  func addBriefAction(_ point: BriefPoint) {
    guard let id = selectedID else { return }
    _ = modifyWorkspace(id) { value in
      guard !value.tasks.contains(where: { $0.title == point.taskTitle }) else { return }
      var task = MeetingTask(title: point.taskTitle)
      task.source = point.sources.first
      value.tasks.append(task)
    }
  }
  var summaryText: String {
    if let brief = insights.brief, let selected { return brief.markdown(for: selected) }
    return [
      ("Резюме", insights.summary), ("Решения", insights.decisions),
      ("Открытые вопросы", insights.questions),
    ]
    .map { heading, sources in
      "## \(heading)\n\n"
        + sources.map { "- [\(timestamp($0.start))] \($0.text)" }.joined(separator: "\n")
    }
    .joined(separator: "\n\n")
  }
  func export(tasksOnly: Bool = false) {
    guard let meeting = selected, exportPanel == nil else { return }
    let contents = tasksOnly ? workspace.markdown : markdown + "\n\n" + workspace.markdown
    guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let panel = NSSavePanel()
    exportPanel = panel
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    let safeName = meeting.title.components(separatedBy: CharacterSet(charactersIn: "/:\n")).joined(
      separator: "-")
    panel.nameFieldStringValue = String(safeName.prefix(100)) + (tasksOnly ? "-задачи.md" : ".md")
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      self?.exportPanel = nil
      guard response == .OK, let destination = panel.url else { return }
      do {
        try SessionStore.writePrivate(Data(contents.utf8), to: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
      } catch { Task { @MainActor in self?.error = error.localizedDescription } }
    }
    NSApp.activate(ignoringOtherApps: true)
    if let window = presentationWindow ?? NSApp.keyWindow ?? NSApp.mainWindow {
      window.makeKeyAndOrderFront(nil)
      panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }
  func revealFiles() { NSWorkspace.shared.open(selectedID.map(store.directory) ?? store.root) }
  func revealLibrary() { NSWorkspace.shared.open(store.root) }
  func openRecording() {
    if let recording { select(recording.meeting) }
    onOpenWorkspace?()
  }
  func prepareForExit() async {
    isTerminating = true
    if recording != nil {
      while isStarting { try? await Task.sleep(for: .milliseconds(50)) }
      if isRecording { await stop() }
    }
    queueWorker?.cancel()
    liveWorker?.cancel()
    liveNotesTask?.cancel()
    await queueWorker?.value
    await liveWorker?.value
    await liveNotesTask?.value
    await speech.shutdown()
    do { try persistQueue() } catch { self.error = error.localizedDescription }
  }
}

private struct MeetingSnapshot: Sendable {
  var results: [Transcription] = []
  var notes: [TimelineNote] = []
  var saved: SavedProtocol?
  var workspace: MeetingWorkspace?
  var errors: [String] = []
  static func load(store: SessionStore, id: UUID) -> Self {
    var value = Self()
    do { value.results = try store.results(id) } catch {
      value.errors.append(error.localizedDescription)
    }
    do { value.notes = try store.notes(id) } catch {
      value.errors.append(error.localizedDescription)
    }
    do { value.saved = try store.savedProtocol(id) } catch {
      value.errors.append(error.localizedDescription)
    }
    do { value.workspace = try store.workspace(id) } catch {
      value.errors.append(error.localizedDescription)
    }
    return value
  }
}
extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
