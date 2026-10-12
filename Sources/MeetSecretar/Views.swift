import AppKit
import MeetingCore
import SwiftUI

enum Palette {
  static let base = Color(red: 32 / 255, green: 33 / 255, blue: 35 / 255)
  static let sidebar = Color(red: 25 / 255, green: 26 / 255, blue: 29 / 255)
  static let card = Color(red: 42 / 255, green: 43 / 255, blue: 47 / 255)
  static let raised = Color(red: 50 / 255, green: 51 / 255, blue: 56 / 255)
  static let border = Color(red: 65 / 255, green: 66 / 255, blue: 72 / 255)
  static let accent = Color(red: 214 / 255, green: 0, blue: 0)
  static let highlight = Color(red: 1, green: 0.39, blue: 0.39)
  static let text = Color(red: 232 / 255, green: 232 / 255, blue: 237 / 255)
  static let muted = Color(red: 165 / 255, green: 165 / 255, blue: 174 / 255)
  // Secondary content remains neutral; red is reserved for actions and recording.
  static let mint = text
  static let cyan = muted
  static let violet = muted
}

struct MainView: View {
  @ObservedObject var model: AppModel
  @State private var query = ""
  @State private var deleteCandidate: Meeting?
  @State private var renameCandidate: Meeting?
  @State private var readingMode = false
  @FocusState private var titleFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      sidebar.frame(width: 270)
      Divider().overlay(Palette.border)
      VStack(alignment: .leading, spacing: 0) {
        if !readingMode || model.page != .meetings || model.selected == nil { header }
        if model.isRecording { recordingBanner }
        Group {
          switch model.page {
          case .tasks: TaskBoard(model: model)
          case .queue: ProcessingQueueView(model: model)
          case .meetings:
            if let meeting = model.selected { detail(meeting).id(meeting.id) } else { setup }
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        if let error = model.error {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).font(.system(size: 12)).lineLimit(4).textSelection(.enabled)
            Spacer()
            Button {
              model.error = nil
            } label: {
              Image(systemName: "xmark").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Закрыть сообщение")
          }.padding(12).background(.orange.opacity(0.12)).clipShape(
            RoundedRectangle(cornerRadius: 9)
          )
          .padding(.horizontal, 26).padding(.bottom, 12)
        }
        HStack {
          Image(systemName: "lock.shield")
          Text(model.statusText).lineLimit(1)
          Spacer()
          Text(
            "COOL ASSIST AI · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0")"
          )
        }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 26)
          .padding(.vertical, 12).background(Palette.sidebar.opacity(0.6))
      }
    }.background {
      Palette.base.overlay(alignment: .topTrailing) {
        LinearGradient(
          colors: [Palette.accent.opacity(0.012), .clear], startPoint: .topTrailing,
          endPoint: .bottomLeading)
      }
    }.foregroundStyle(Palette.text)
      .preferredColorScheme(.dark).tint(Palette.highlight).frame(minWidth: 900, minHeight: 600)
      .onChange(of: model.selectedID) { _, _ in readingMode = false }
      .onChange(of: model.page) { _, _ in readingMode = false }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.page)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: readingMode)
      .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
      .sheet(item: $renameCandidate) { meeting in RenameMeetingView(model: model, meeting: meeting)
      }
      .alert(
        "Удалить встречу?",
        isPresented: Binding(
          get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }),
        presenting: deleteCandidate
      ) { meeting in
        Button("Переместить в Корзину", role: .destructive) { model.deleteMeeting(meeting) }
        Button("Отмена", role: .cancel) {}
      } message: { meeting in
        Text(
          "«\(meeting.title)» и все её материалы будут перемещены в Корзину macOS. Экспортированные файлы сохранятся."
        )
      }
  }
  private var filteredMeetings: [Meeting] {
    model.meetings.filter {
      (model.projectFilter.isEmpty || $0.project == model.projectFilter)
        && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
          || ($0.project ?? "").localizedCaseInsensitiveContains(query))
    }
  }
  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        BrandMark(size: 38)
        VStack(alignment: .leading, spacing: 3) {
          Text("Cool Assist Ai").font(.system(size: 19, weight: .semibold))
          Text("РАЗГОВОР. СМЫСЛ. ДЕЙСТВИЕ.").font(.system(size: 8, weight: .medium)).tracking(0.65)
            .foregroundStyle(Palette.muted)
        }.ignoresSafeArea()
      }.padding(.top, 20).padding(.bottom, 7)
      Button {
        model.select(nil)
        titleFocused = true
      } label: {
        HStack {
          Image(systemName: "plus")
          Text("Новая встреча")
          Spacer()
          Text("⌘N").opacity(0.5)
        }
        .font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
      }.buttonStyle(SurfaceButtonStyle(prominent: true)).keyboardShortcut("n")
        .help("Новая встреча · ⌘N")
      VStack(spacing: 4) {
        navigation("Встречи", icon: "square.grid.2x2", count: model.meetings.count, page: .meetings)
        navigation("Все задачи", icon: "checklist", count: model.openTaskCount, page: .tasks)
        navigation(
          "Обработка", icon: "arrow.triangle.2.circlepath", count: model.jobs.count, page: .queue)
      }
      Divider().padding(.vertical, 2)
      HStack {
        Text("ВСТРЕЧИ").tracking(1.4)
        Spacer()
        Text("\(model.meetings.count)")
      }.font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
        TextField("Найти встречу", text: $query).textFieldStyle(.plain)
          .accessibilityLabel("Поиск встреч")
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill").frame(width: 22, height: 22)
          }.buttonStyle(.plain).accessibilityLabel("Очистить поиск")
        }
      }.font(.system(size: 12)).padding(10).background(Palette.card.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 9))
      if !model.projects.isEmpty {
        Picker("Проект", selection: $model.projectFilter) {
          Text("Все проекты").tag("")
          ForEach(model.projects, id: \.self) { Text($0).tag($0) }
        }.labelsHidden().accessibilityLabel("Фильтр проектов")
      }
      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(filteredMeetings) { meeting in
            meetingRow(meeting).contextMenu {
              Button("Название и проект…") { renameCandidate = meeting }.disabled(
                !model.canChangeMeeting(meeting.id))
              Button("Удалить встречу…", role: .destructive) { deleteCandidate = meeting }
                .disabled(!model.canChangeMeeting(meeting.id))
            }
          }
          if filteredMeetings.isEmpty {
            Text(
              model.meetings.isEmpty
                ? "Запишите первую встречу.\nРешения и задачи останутся здесь."
                : "Ничего не найдено"
            )
            .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(5).padding(.top, 15)
            if !query.isEmpty || !model.projectFilter.isEmpty {
              Button("Сбросить фильтры") {
                query = ""
                model.projectFilter = ""
              }
            }
          }
        }
      }
      Divider()
      Button {
        model.showSettings = true
        model.refreshPermissions()
        if model.captureSystemAudio && model.screenAllowed {
          Task { await model.refreshDisplays() }
        }
      } label: {
        HStack {
          Label("Настройки", systemImage: "slider.horizontal.3")
          Spacer()
          Text("⌘,").foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity, minHeight: 20).padding(12)
      }
      .buttonStyle(SurfaceButtonStyle(bordered: false)).keyboardShortcut(",")
      .font(.system(size: 12)).padding(.bottom, 6)
    }.padding(.horizontal, 16).padding(.bottom, 12).background(Palette.sidebar)
  }
  private func meetingRow(_ meeting: Meeting) -> some View {
    let selected = model.selectedID == meeting.id && model.page == .meetings
    let statusColor: Color =
      meeting.status == .complete && model.job(meeting.id) == nil
      ? Palette.muted : .orange
    return Button {
      model.select(meeting)
    } label: {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 10) {
          Text(meeting.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 0)
          Image(systemName: selected ? "arrow.up.right" : "chevron.right").font(
            .system(size: 10, weight: .semibold)
          )
          .foregroundStyle(selected ? Palette.highlight : Palette.muted.opacity(0.65))
        }
        if let project = meeting.project {
          Text(project).font(.system(size: 10)).foregroundStyle(Palette.highlight).lineLimit(1)
        }
        HStack(spacing: 5) {
          Circle().fill(statusColor).frame(width: 5, height: 5)
          Text(model.status(meeting)).lineLimit(1).foregroundStyle(statusColor)
          Spacer(minLength: 0)
        }.font(.system(size: 10))
        HStack {
          Text(
            meeting.startedAt.formatted(
              .dateTime.locale(Locale(identifier: "ru_RU")).day().month(.abbreviated)))
          Spacer()
          Text(timestamp(meeting.duration)).monospacedDigit()
        }.font(.system(size: 10)).foregroundStyle(Palette.muted)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .contentShape(Rectangle())
    }.buttonStyle(SurfaceButtonStyle(selected: selected))
      .accessibilityLabel(meeting.title)
      .accessibilityValue(model.status(meeting) + (selected ? ", выбрана" : ""))
      .accessibilityAddTraits(selected ? .isSelected : [])
      .accessibilityIdentifier("meeting-\(meeting.id.uuidString)")
      .help("Открыть встречу «\(meeting.title)»")
  }
  private func navigation(_ name: String, icon: String, count: Int, page: WorkspacePage)
    -> some View
  {
    Button {
      model.page = page
      if page == .tasks { model.refreshTaskBoard() }
    } label: {
      HStack(spacing: 10) {
        IconTile(symbol: icon, color: page == .tasks ? Palette.cyan : Palette.violet, size: 28)
        Text(name)
        Spacer()
        Text("\(count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
          .foregroundStyle(model.page == page ? Palette.highlight : Palette.muted)
          .padding(.horizontal, 7).padding(.vertical, 3)
          .background(.white.opacity(0.04), in: Capsule())
      }
      .font(.system(size: 13)).frame(minHeight: 22).padding(11).contentShape(Rectangle())
    }.buttonStyle(SurfaceButtonStyle(selected: model.page == page, bordered: false))
      .accessibilityAddTraits(model.page == page ? .isSelected : [])
  }
  private var header: some View {
    HStack {
      Text(
        model.page == .tasks
          ? "ЗАДАЧИ ИЗ ВСТРЕЧ" : model.page == .queue ? "ФОНОВАЯ ОБРАБОТКА" : "РАБОЧЕЕ ПРОСТРАНСТВО"
      )
      .font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(Palette.muted)
      Spacer()
      StatusBadge(
        text: model.modelsReady ? "Речь — на Mac" : "AI недоступен",
        symbol: model.modelsReady ? "checkmark.shield" : "exclamationmark.triangle",
        color: model.modelsReady ? Palette.mint : .orange)
    }.padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
  }
  private var recordingBanner: some View {
    HStack(spacing: 12) {
      Circle().fill(model.isPaused ? .orange : Palette.accent).frame(width: 7, height: 7)
      Button {
        model.openRecording()
      } label: {
        Text("\(model.recordingTitle) · \(timestamp(model.elapsed))").lineLimit(1)
          .padding(.vertical, 7).contentShape(Rectangle())
      }.buttonStyle(.plain).help("Открыть текущую запись")
      Text(model.isPaused ? "На паузе" : "Идёт запись").foregroundStyle(Palette.muted)
      Spacer()
      Button(model.isPaused ? "Продолжить" : "Пауза") { Task { await model.togglePause() } }
      Button("Завершить") { Task { await model.stop() } }
    }.font(.system(size: 12)).padding(12).background(Palette.accent.opacity(0.09))
      .clipShape(RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 28).padding(.bottom, 16)
      .disabled(model.isStopping)
  }
  private var setup: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 18) {
          VStack(alignment: .leading, spacing: 10) {
            Text("Новая встреча")
              .font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.4)
            Text("Сосредоточьтесь на разговоре.\nГлавное останется под рукой.")
              .font(.system(size: 13)).lineSpacing(4).foregroundStyle(Palette.muted)
          }
          Spacer(minLength: 8)
          MeetingWaveform().frame(width: 116, height: 64)
        }.padding(.vertical, 6)
        HStack(spacing: 10) {
          workflowStep("Речь в текст", icon: "waveform", color: Palette.accent)
          workflowStep("Главное по темам", icon: "text.alignleft", color: Palette.violet)
          workflowStep("План действий", icon: "checklist", color: Palette.cyan)
        }
        VStack(alignment: .leading, spacing: 17) {
          HStack {
            Label("Подготовка к записи", systemImage: "record.circle").font(
              .system(size: 14, weight: .semibold))
            Spacer()
            Text("01 / ЗАПИСЬ").font(.system(size: 9, weight: .semibold)).tracking(1)
              .foregroundStyle(Palette.muted)
          }
          TextField("Название встречи", text: $model.title).textFieldStyle(.plain).font(
            .system(size: 19)
          )
          .padding(13).background(Palette.base).clipShape(RoundedRectangle(cornerRadius: 8))
          .accessibilityLabel("Название новой встречи")
          .focused($titleFocused)
          .contentShape(Rectangle())
          .simultaneousGesture(TapGesture().onEnded { titleFocused = true })
          HStack {
            TextField("Проект — необязательно", text: $model.project).textFieldStyle(.roundedBorder)
            if !model.projects.isEmpty {
              Menu {
                ForEach(model.projects, id: \.self) { name in Button(name) { model.project = name }
                }
              } label: {
                Image(systemName: "folder")
              }.menuStyle(.borderlessButton).frame(width: 24)
                .accessibilityLabel("Выбрать проект").help("Выбрать существующий проект")
            }
            Picker("Язык", selection: $model.language) { languages }.frame(width: 215)
          }
          CaptureModeView(model: model)
            .disabled(model.isRecording || model.isStarting)
          HStack {
            if model.captureSystemAudio {
              Toggle("Сохранять видео экрана", isOn: $model.recordScreen)
                .font(.system(size: 12)).disabled(model.isRecording || model.isStarting)
            }
            Spacer()
            if model.capturePermissionsReady {
              Label("Доступ разрешён", systemImage: "checkmark.shield")
                .font(.system(size: 11)).foregroundStyle(Palette.text)
            } else {
              Button("Настроить доступ") {
                model.settingsSection = .recording
                model.showSettings = true
              }.font(.system(size: 12))
            }
          }
          Divider().overlay(.white.opacity(0.04))
          HStack(spacing: 18) {
            Button {
              Task { await model.start() }
            } label: {
              Label(
                model.isStarting ? "Подготовка…" : "Начать запись", systemImage: "record.circle"
              )
              .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 22).padding(
                .vertical, 13
              )
              .contentShape(Rectangle())
            }.buttonStyle(SurfaceButtonStyle(prominent: true))
              .disabled(
                !model.canStart || model.showSettings || renameCandidate != nil
                  || deleteCandidate != nil
              )
              .keyboardShortcut(.return, modifiers: .command).help("Начать запись · ⌘Return")
            Text(
              model.isRecording
                ? "Сначала завершите текущую запись.\nС материалами можно работать сейчас."
                : "Во время записи останется маленькая панель.\nИз неё можно открыть рабочее пространство."
            )
            .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            Spacer(minLength: 0)
          }
        }.padding(22).panelSurface()
        SummaryModeView(model: model)
        Label("Используйте наушники и предупредите участников о записи.", systemImage: "headphones")
          .font(.system(size: 11)).foregroundStyle(Palette.muted)
      }.padding(.horizontal, 28).padding(.bottom, 28)
        .task {
          // AppKit assigns its initial responder while the new form is being mounted.
          titleFocused = false
          try? await Task.sleep(for: .milliseconds(100))
          guard !Task.isCancelled else { return }
          titleFocused = true
        }
        .onDisappear { titleFocused = false }
    }
  }
  private func workflowStep(_ title: String, icon: String, color: Color) -> some View {
    HStack(spacing: 9) {
      IconTile(symbol: icon, color: color, size: 28)
      Text(title).font(.system(size: 11, weight: .medium)).lineLimit(2)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(10).panelSurface(
      tint: color, cornerRadius: 12)
  }
  private func detail(_ meeting: Meeting) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      if readingMode {
        HStack(spacing: 12) {
          Text(meeting.title).font(.system(size: 19, weight: .semibold, design: .rounded))
            .lineLimit(1)
          Spacer(minLength: 8)
          Button {
            readingMode = false
          } label: {
            Label("Вернуть панели", systemImage: "arrow.down.right.and.arrow.up.left")
              .font(.system(size: 12, weight: .medium)).padding(11).contentShape(Rectangle())
          }.buttonStyle(SurfaceButtonStyle(selected: true))
        }.padding(.top, 28)
      } else {
        meetingControls(meeting)
      }
      GeometryReader { geometry in
        HStack(alignment: .top, spacing: 18) {
          VStack(spacing: 14) {
            DocumentTabs(
              choices: [.overview, .transcript, .tasks, .notes, .markdown],
              selection: $model.selectedTab,
              title: { $0 == .transcript ? "Полный текст" : $0.rawValue })
            Group {
              if model.isLoading {
                ProgressView("Открываю материалы…").frame(maxWidth: .infinity, maxHeight: .infinity)
              } else {
                switch model.selectedTab {
                case .overview: OverviewView(model: model)
                case .tasks: MeetingTasksView(model: model, meeting: meeting)
                case .transcript: TranscriptView(model: model)
                case .notes: MeetingNotesView(model: model, meetingID: meeting.id).id(meeting.id)
                case .markdown:
                  MarkdownPreview(
                    text: model.markdown.isEmpty
                      ? "Расшифровка появится во время записи. Итоговый протокол — после обработки."
                      : model.markdown)
                }
              }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).panelSurface(cornerRadius: 13)
          }
          if geometry.size.width >= 820 && model.selectedTab == .overview && !readingMode {
            MeetingActionPanel(model: model, meeting: meeting).frame(width: 252).disabled(
              model.isLoading || !model.workspaceReadable)
          }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.selectedTab)
      }
    }.padding(.horizontal, 28).padding(.bottom, 22)
  }
  private func meetingControls(_ meeting: Meeting) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 14) {
        VStack(alignment: .leading, spacing: 8) {
          if let project = meeting.project {
            Label(project, systemImage: "folder").font(.system(size: 11)).foregroundStyle(
              Palette.highlight)
          }
          Text(meeting.title).font(.system(size: 27, weight: .medium))
            .lineLimit(
              2)
          Text(
            "\(meeting.startedAt.formatted(.dateTime.locale(Locale(identifier: "ru_RU")).day().month(.abbreviated).year().hour().minute())) · \(timestamp(model.recordingID == meeting.id ? model.elapsed : meeting.duration)) · \(model.status(meeting))"
          )
          .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Spacer(minLength: 10)
        Menu {
          Button("Название и проект…") { renameCandidate = meeting }.disabled(
            !model.canChangeMeeting(meeting.id))
          Button("Составить протокол") { model.processSelected() }.disabled(
            model.recordingID == meeting.id || model.job(meeting.id) != nil)
          Button("Открыть файлы") { model.revealFiles() }
          Divider()
          Button("Удалить встречу…", role: .destructive) { deleteCandidate = meeting }.disabled(
            !model.canChangeMeeting(meeting.id))
        } label: {
          Image(systemName: "ellipsis")
        }.menuStyle(.borderlessButton).frame(width: 28).accessibilityLabel("Действия со встречей")
      }
      HStack(spacing: 8) {
        if meeting.status == .complete {
          Button {
            model.summarizeSelected()
          } label: {
            Label(
              model.insights.brief == nil ? "Составить резюме" : "Обновить резюме",
              systemImage: "sparkles"
            )
            .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13).padding(
              .vertical, 11
            ).contentShape(Rectangle())
          }.buttonStyle(SurfaceButtonStyle(prominent: model.insights.brief == nil))
            .disabled(!model.canSummarize)
            .help("Создать резюме по готовой расшифровке с выбранными настройками")
        }
        Button {
          model.export()
        } label: {
          Label("Экспорт .md", systemImage: "square.and.arrow.up")
            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(
              .vertical, 11
            ).contentShape(Rectangle())
        }.buttonStyle(SurfaceButtonStyle()).disabled(model.markdown.isEmpty || model.isLoading)
        Spacer(minLength: 0)
        Button {
          readingMode = true
        } label: {
          Label("Читать", systemImage: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 12, weight: .medium)).padding(.horizontal, 11).padding(
              .vertical, 11
            ).contentShape(Rectangle())
        }.buttonStyle(SurfaceButtonStyle()).help(
          "Расширить документ и временно скрыть панели встречи")
      }
      if let job = model.job(meeting.id) {
        JobStrip(model: model, job: job)
      } else if meeting.status != .complete && model.recordingID != meeting.id {
        HStack(spacing: 12) {
          IconTile(symbol: "arrow.clockwise", color: .orange, size: 32)
          Text("Материалы сохранены.\nМожно продолжить обработку.").font(.system(size: 12))
            .foregroundStyle(Palette.muted).lineSpacing(3)
          Spacer(minLength: 4)
          Button {
            model.processSelected()
          } label: {
            Text("Составить протокол").font(.system(size: 12, weight: .semibold))
              .padding(11).contentShape(Rectangle())
          }.buttonStyle(SurfaceButtonStyle(prominent: true)).disabled(!model.modelsReady)
        }.padding(12).panelSurface(tint: .orange, cornerRadius: 12)
      }
      DisclosureGroup("Настройки резюме · \(model.summaryConfiguration.label)") {
        SummaryModeView(model: model, compact: true).padding(.top, 8)
      }.font(.system(size: 11)).foregroundStyle(Palette.muted)
    }
  }
  private var languages: some View {
    Group {
      Text("Автоопределение").tag("auto")
      Text("Русский").tag("ru")
      Text("Română").tag("ro")
      Text("English").tag("en")
      Text("Українська").tag("uk")
      Text("Deutsch").tag("de")
    }
  }
}
struct MarkdownPreview: NSViewRepresentable {
  let text: String
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let view = NSTextView()
    view.isEditable = false
    view.isSelectable = true
    view.drawsBackground = false
    view.textContainerInset = NSSize(width: 20, height: 20)
    view.autoresizingMask = [.width]
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.textContainer?.widthTracksTextView = true
    scroll.documentView = view
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
    view.string = text
    view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    view.textColor = .white.withAlphaComponent(0.88)
    let full = NSRange(location: 0, length: (text as NSString).length)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 5
    view.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: full)
    if let regex = try? NSRegularExpression(pattern: "(?m)^#{1,4} .+$") {
      for match in regex.matches(in: text, range: full) {
        view.textStorage?.addAttributes(
          [
            .foregroundColor: NSColor(calibratedRed: 1, green: 0.39, blue: 0.39, alpha: 1),
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
          ], range: match.range)
      }
    }
  }
}

struct RecordingWidget: View {
  @ObservedObject var model: AppModel
  @State private var marked = false

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 13) {
        Circle().fill(model.isPaused ? Color.orange : Palette.accent).frame(width: 9, height: 9)
        VStack(alignment: .leading, spacing: 3) {
          Text(timestamp(model.elapsed)).font(
            .system(size: 19, weight: .semibold, design: .monospaced))
          Text(model.isPaused ? "НА ПАУЗЕ" : "ЗАПИСЬ НА MAC")
            .font(.system(size: 8, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.muted)
        }
        LiveWaveform(
          level: max(model.micLevel, model.recordingSystemAudio ? model.systemLevel : 0),
          paused: model.isPaused)
        VStack(alignment: .leading, spacing: 5) {
          meter("mic.fill", value: model.micLevel)
          if model.recordingSystemAudio { meter("speaker.wave.2.fill", value: model.systemLevel) }
        }
        Spacer(minLength: 0)
        Divider().frame(height: 28)
        widgetButton(
          marked ? "bookmark.fill" : "bookmark",
          label: marked ? "Момент отмечен" : "Отметить важный момент"
        ) {
          model.markMoment()
          marked = true
        }
        widgetButton(
          model.isPaused ? "play.fill" : "pause.fill",
          label: model.isPaused ? "Продолжить запись" : "Поставить запись на паузу"
        ) {
          Task { await model.togglePause() }
        }
        Button {
          Task { await model.stop() }
        } label: {
          Image(systemName: "stop.fill").font(.system(size: 13))
            .foregroundStyle(Palette.text).frame(width: 40, height: 40)
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 13))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("Завершить встречу").accessibilityLabel("Завершить встречу")
        widgetButton("arrow.up.left.and.arrow.down.right", label: "Открыть рабочее пространство") {
          model.openRecording()
        }
      }.disabled(model.isStopping || !model.isRecording)
      Text(
        model.isPaused
          ? "Запись на паузе. Нажмите ▶, чтобы продолжить."
          : model.liveText.isEmpty ? "Слушаю… Текст появится по ходу речи." : model.liveText
      )
      .font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(model.liveText.isEmpty || model.isPaused ? Palette.muted : Palette.text)
      HStack {
        Text(model.recordingTitle).lineLimit(1)
        Spacer(minLength: 10)
        Text(
          model.error != nil
            ? "Ошибка — откройте приложение"
            : model.isStopping
              ? model.statusText
              : marked
                ? "Важный момент сохранён"
                : model.pendingCount > 0
                  ? "Распознаю · в очереди \(model.pendingCount)" : "Распознавание на Mac"
        )
        .lineLimit(1)
      }.font(.system(size: 9)).foregroundStyle(model.error == nil ? Palette.muted : .orange)
    }.padding(.horizontal, 17).padding(.vertical, 13)
      .frame(width: 580, height: 128).background(Palette.base).foregroundStyle(Palette.text)
      .clipShape(RoundedRectangle(cornerRadius: 19))
      .overlay(
        RoundedRectangle(cornerRadius: 19).strokeBorder(
          model.isPaused ? Palette.muted.opacity(0.3) : Palette.accent.opacity(0.45))
      )
      .preferredColorScheme(.dark)
      .task(id: marked) {
        guard marked else { return }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        marked = false
      }
  }

  private func widgetButton(_ symbol: String, label: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 14)).frame(width: 34, height: 40).contentShape(
        Rectangle())
    }.buttonStyle(SurfaceButtonStyle(bordered: false)).help(label).accessibilityLabel(label)
  }

  private func meter(_ symbol: String, value: Double) -> some View {
    let level = model.isPaused ? 0 : min(1, max(0, value))
    return HStack(spacing: 5) {
      Image(systemName: symbol).font(.system(size: 8)).frame(width: 12).foregroundStyle(
        Palette.muted)
      HStack(spacing: 2) {
        ForEach(0..<7) { index in
          RoundedRectangle(cornerRadius: 1).fill(
            Double(index) / 7 < level ? Palette.accent : Color.white.opacity(0.12)
          )
          .frame(width: 3, height: 5)
        }
      }
    }.accessibilityLabel(symbol == "mic.fill" ? "Уровень микрофона" : "Уровень звука встречи")
      .accessibilityValue("\(Int(level * 100)) процентов")
  }
}
