import AppKit
import MeetingCore

extension AppModel {
  func start() async {
    guard canStart else { return }
    isStarting = true
    // Keep the selected sources fixed while permission dialogs and AI warmup are pending.
    let captureSystemAudio = self.captureSystemAudio
    let recordScreen = captureSystemAudio && self.recordScreen
    let useOCR = captureSystemAudio && self.useOCR
    let microphoneID = self.microphoneID
    let displayID = self.displayID
    error = nil
    statusText = "Проверяю доступ к устройствам…"
    defer { isStarting = false }
    do {
      try await authorization.authorize(requiresScreen: captureSystemAudio)
      guard !isTerminating else { return }
      if captureSystemAudio { noteScreenAuthorizationSuccess() }
      refreshPermissions()
      try ai.paths.validate()
      try ensureDiskSpace()
      try await speech.prepare()
      var meeting = Meeting(
        title: title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
          ?? "Встреча \(Date().formatted(date: .abbreviated, time: .shortened))",
        language: language, screenRecorded: recordScreen)
      meeting.project = project.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      try store.create(meeting)
      let session = RecordingSession(meeting, capturesSystemAudio: captureSystemAudio)
      recording = session
      elapsed = 0
      pendingCount = 0
      liveText = ""
      micLevel = 0
      systemLevel = 0
      autoStopReason = nil
      isPaused = false
      lastMeterAt = [:]
      let capture = captureFactory()
      capture.onLevel = { [weak self] source, value in
        Task { @MainActor in
          guard let self, self.recordingID == meeting.id else { return }
          if source == .microphone { self.micLevel = value } else { self.systemLevel = value }
          self.lastMeterAt[source] = Date()
        }
      }
      capture.onChunk = { [weak self] chunk in
        Task { @MainActor in
          guard let self, self.recordingID == meeting.id else { return }
          session.chunks.append(chunk)
        }
      }
      capture.onNote = { [weak self] note in
        Task { @MainActor in
          guard let self, self.recordingID == meeting.id else { return }
          self.appendNote(note, session: session)
        }
      }
      capture.onError = { [weak self] message in
        Task { @MainActor in
          guard let self, self.recordingID == meeting.id else { return }
          session.captureError = message
          self.recordIssue(message, session: session)
          self.error = message
          if self.isRecording && !self.isStopping {
            self.autoStopReason = message
            await self.stop()
          }
        }
      }
      self.capture = capture
      try await capture.start(
        directory: store.directory(meeting.id), displayID: displayID,
        microphone: microphoneID, recordScreen: recordScreen, useOCR: useOCR,
        captureSystemAudio: captureSystemAudio)
      if let captureError = session.captureError { throw MeetingError.message(captureError) }
      isRecording = true
      if !captureSystemAudio {
        appendNote(
          TimelineNote(time: 0, kind: "Источники записи", text: "Запись только микрофона."),
          session: session)
      }
      activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .idleSystemSleepDisabled], reason: "Запись встречи Meet Protocol")
      try refreshLibrary()
      select(meeting)
      title = ""
      statusText = captureSystemAudio ? "Слушаю и сохраняю встречу" : "Записываю микрофон"
      onRecordingChanged?(true)
      timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.tick() }
      }
      liveWorker = Task { [weak self] in await self?.transcribeLive(session) }
    } catch {
      if captureSystemAudio { noteScreenAuthorizationFailure(error) }
      if let capture {
        do { _ = try await capture.stop() } catch { self.error = error.localizedDescription }
      }
      capture = nil
      timer?.invalidate()
      timer = nil
      isRecording = false
      if let activity {
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
      }
      if let recording {
        recording.meeting.status = .interrupted
        recording.meeting.issues.append(error.localizedDescription)
        do {
          try store.save(recording.meeting)
          try refreshLibrary()
        } catch { self.error = error.localizedDescription }
      }
      recording = nil
      self.error = "Не удалось начать запись: \(error.localizedDescription)"
      statusText =
        captureSystemAudio
        ? "Проверьте доступ или выберите «Только микрофон»"
        : "Проверьте доступ к микрофону и настройки устройства"
      onRecordingChanged?(false)
    }
  }
  private func tick() {
    guard isRecording, let recording else { return }
    elapsed = Date().timeIntervalSince(recording.meeting.startedAt)
    if let date = lastMeterAt[.microphone], Date().timeIntervalSince(date) > 2 { micLevel = 0 }
    if let date = lastMeterAt[.system], Date().timeIntervalSince(date) > 2 { systemLevel = 0 }
    if Int(elapsed) % 10 == 0 {
      do {
        recording.meeting.duration = elapsed
        try store.save(recording.meeting)
        try ensureDiskSpace()
      } catch {
        self.error = error.localizedDescription
        autoStopReason = error.localizedDescription
        Task { await stop() }
      }
    }
  }
  private func ensureDiskSpace() throws {
    let values = try store.root.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey
    ])
    if let bytes = values.volumeAvailableCapacityForImportantUsage, bytes < 1_000_000_000 {
      throw MeetingError.message("На диске меньше 1 ГБ. Освободите место для записи.")
    }
  }
  func togglePause() async {
    guard isRecording, !isStopping, !changingPause, let recording else { return }
    changingPause = true
    defer { changingPause = false }
    do {
      let paused = !isPaused
      try await capture?.setPaused(paused)
      isPaused = paused
      micLevel = 0
      systemLevel = 0
      appendNote(
        TimelineNote(
          time: elapsed, kind: "Запись",
          text: paused ? "Пауза: аудио, видео и OCR не сохраняются." : "Запись возобновлена."),
        session: recording)
    } catch {
      self.error = error.localizedDescription
      autoStopReason = error.localizedDescription
      await stop()
    }
  }
  func markMoment() {
    guard isRecording, !isStopping, let recording else { return }
    appendNote(
      TimelineNote(
        time: elapsed, kind: "Метка пользователя",
        text: "Важный момент — проверить в расшифровке."), session: recording)
  }
  func stop() async {
    guard isRecording, !isStopping, let session = recording else { return }
    isStopping = true
    defer { isStopping = false }
    timer?.invalidate()
    timer = nil
    elapsed = Date().timeIntervalSince(session.meeting.startedAt)
    statusText = "Сохраняю последние фрагменты…"
    do {
      let received = try await capture?.stop() ?? []
      let expected: [AudioSource] =
        session.capturesSystemAudio ? AudioSource.allCases : [.microphone]
      for source in expected where !received.contains(source) {
        recordIssue(
          "Не получены данные: \(source.label). Проверьте устройство и разрешения.",
          session: session)
      }
    } catch {
      recordIssue(error.localizedDescription, session: session)
      self.error = error.localizedDescription
      autoStopReason = error.localizedDescription
    }
    capture = nil
    // Finish only the current inference cancellation, not a meeting-sized backlog.
    liveWorker?.cancel()
    liveNotesTask?.cancel()
    await liveWorker?.value
    await liveNotesTask?.value
    liveWorker = nil
    liveNotesTask = nil
    session.meeting.duration = elapsed
    session.meeting.status = autoStopReason == nil ? .captured : .interrupted
    do {
      try store.save(session.meeting)
      try saveLiveDraft(session)
      try refreshLibrary()
    } catch { self.error = error.localizedDescription }
    recording = nil
    isRecording = false
    isPaused = false
    micLevel = 0
    systemLevel = 0
    pendingCount = 0
    if let activity {
      ProcessInfo.processInfo.endActivity(activity)
      self.activity = nil
    }
    if autoStopReason == nil {
      enqueue(session.meeting.id)
    } else {
      statusText = "Запись прервана; материалы сохранены"
    }
    if selectedID == session.meeting.id { reloadSelected() }
    onRecordingChanged?(false)
  }
  private func transcribeLive(_ session: RecordingSession) async {
    while !Task.isCancelled, recordingID == session.meeting.id {
      do {
        let done = Set(session.results.map(\.id))
        let pending = session.chunks.filter { !done.contains($0.id) }
        pendingCount = pending.count
        if let chunk = pending.first(where: { !session.failed.contains($0.id) }) {
          liveNotesTask?.cancel()
          await liveNotesTask?.value
          liveNotesTask = nil
          do {
            let result = try await ai.transcribe(
              chunk, directory: store.directory(session.meeting.id),
              language: session.meeting.language, worker: speech, priority: .live)
            try store.save(result, meetingID: session.meeting.id)
            session.results.append(result)
            session.results.sort { $0.chunk.start < $1.chunk.start }
            liveText = session.results.reversed().lazy.flatMap { $0.utterances.reversed() }
              .prefix(2).reversed().map(\.text).joined(separator: " ")
            pendingCount = max(0, pendingCount - 1)
            if selectedID == session.meeting.id {
              results = session.results
              rebuildTranscript()
            }
            if Date().timeIntervalSince(session.lastDraftAt) >= 10 {
              try saveLiveDraft(session)
              session.lastDraftAt = Date()
            }
          } catch is CancellationError { return } catch {
            session.failed.insert(chunk.id)
            recordIssue(
              "Не распознан \(timestamp(chunk.start)): \(error.localizedDescription)",
              session: session)
          }
        } else {
          prepareLiveNoteIfIdle(session)
          try await Task.sleep(for: .milliseconds(250))
        }
      } catch is CancellationError { return } catch {
        self.error = error.localizedDescription
        return
      }
    }
  }
  private func prepareLiveNoteIfIdle(_ session: RecordingSession) {
    guard !jobs.contains(where: { $0.state == .running || $0.state == .queued }),
      liveNotesTask == nil, pendingCount == 0, elapsed - session.lastLiveNote >= 120
    else { return }
    session.lastLiveNote = elapsed
    let text = Markdown.transcript(session.results.filter { $0.chunk.start >= elapsed - 150 })
    guard !text.isEmpty, text.count <= 6000 else { return }
    let time = elapsed
    liveNotesTask = Task { [weak self] in
      guard let self else { return }
      defer { self.liveNotesTask = nil }
      do {
        let note = try await self.ai.generate(
          instruction:
            "Предварительные заметки: тема, предложения, возражения, вопросы. До 120 слов. Не делай окончательных выводов.",
          input: text,
          directory: self.store.directory(session.meeting.id).appendingPathComponent("drafts"),
          tokens: 350)
        try Task.checkCancellation()
        self.appendNote(
          TimelineNote(time: time, kind: "Предварительная AI-заметка", text: note), session: session
        )
      } catch is CancellationError { return } catch {
        self.recordIssue(error.localizedDescription, session: session)
      }
    }
  }
  private func recordIssue(_ text: String, session: RecordingSession) {
    if !session.meeting.issues.contains(text) { session.meeting.issues.append(text) }
  }
  private func appendNote(_ note: TimelineNote, session: RecordingSession) {
    do {
      try store.save(note, meetingID: session.meeting.id)
      session.notes.append(note)
      if selectedID == session.meeting.id { notes = session.notes }
    } catch {
      recordIssue("Не удалось сохранить заметку: \(error.localizedDescription)", session: session)
      self.error = error.localizedDescription
    }
  }
  private func saveLiveDraft(_ session: RecordingSession) throws {
    let text = Markdown.document(
      meeting: session.meeting, results: session.results,
      notes: session.notes, pendingCount: pendingCount)
    _ = try store.writeMarkdown(text, id: session.meeting.id)
    if selectedID == session.meeting.id { markdown = text }
  }
}
