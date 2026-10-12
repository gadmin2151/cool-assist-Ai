import MeetingCore
import SwiftUI

struct MetricCard: View {
  let value: String
  let label: String
  let icon: String
  var color: Color = Palette.highlight
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        IconTile(symbol: icon, color: color, size: 30)
        Spacer()
        Text(value).font(.system(size: 25, weight: .semibold, design: .rounded))
      }
      Text(label).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
    }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
      .panelSurface(tint: color, cornerRadius: 13).contentShape(Rectangle())
  }
}
struct EmptyCard: View {
  let icon: String
  let title: String
  let text: String
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      IconTile(symbol: icon, color: Palette.cyan, size: 42)
      Text(title).font(.system(size: 18, weight: .semibold, design: .rounded))
      Text(text).font(.system(size: 13)).lineSpacing(5).foregroundStyle(Palette.muted)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
      .panelSurface(tint: Palette.cyan)
  }
}

private struct SummaryCopyButton: View {
  @ObservedObject var model: AppModel
  @State private var copied = false

  var body: some View {
    Button {
      model.copyText(model.summaryText)
      copied = true
    } label: {
      Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
    }.buttonStyle(SurfaceButtonStyle(selected: copied))
      .help("Копировать резюме встречи")
      .task(id: copied) {
        guard copied else { return }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        copied = false
      }
  }
}
struct OverviewView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        if let brief = model.insights.brief {
          BriefView(model: model, brief: brief)
          DisclosureGroup("Реплики, решения и открытые вопросы") {
            VStack(alignment: .leading, spacing: 18) {
              evidenceSection(
                "Решения", icon: "checkmark.seal", sources: model.insights.decisions,
                empty: "Явно принятые решения не выделены.")
              evidenceSection(
                "Открытые вопросы", icon: "questionmark.bubble", sources: model.insights.questions,
                empty: "Нерешённые вопросы не выделены.")
            }.padding(.top, 14)
          }.font(.system(size: 12)).foregroundStyle(Palette.muted)
        } else if model.insights.summary.isEmpty {
          EmptyCard(
            icon: "text.alignleft",
            title: model.recordingID == model.selectedID
              ? "Встреча продолжается" : "Резюме ещё не подготовлено",
            text:
              "Речь доступна в расшифровке. После обработки здесь появятся ключевые пункты, решения и открытые вопросы."
          )
        } else {
          HStack {
            IconTile(symbol: "text.alignleft")
            Text("Главное за встречу").font(.system(size: 18, weight: .semibold))
            Spacer()
            SummaryCopyButton(model: model)
          }
          ForEach(model.insights.summary) { source in EvidenceRow(model: model, source: source) }
          HStack(spacing: 12) {
            MetricCard(
              value: "\(model.insights.decisions.count)",
              label: countWord(model.insights.decisions.count, "решение", "решения", "решений"),
              icon: "checkmark.seal")
            Button {
              model.selectedTab = .tasks
            } label: {
              MetricCard(
                value: "\(model.workspace.tasks.filter { !$0.isComplete }.count)",
                label: "задач осталось", icon: "checklist", color: Palette.cyan)
            }.buttonStyle(.plain).help("Открыть задачи встречи")
            MetricCard(
              value: "\(model.insights.questions.count)",
              label: countWord(
                model.insights.questions.count, "открытый вопрос", "открытых вопроса",
                "открытых вопросов"),
              icon: "questionmark.bubble", color: Palette.violet)
          }
          evidenceSection(
            "Решения", icon: "checkmark.seal", sources: model.insights.decisions,
            empty: "Явно принятые решения не выделены.")
          evidenceSection(
            "Открытые вопросы", icon: "questionmark.bubble", sources: model.insights.questions,
            empty: "Нерешённые вопросы не выделены.")
          if !model.insights.topics.isEmpty {
            Text("Темы обсуждения").font(.system(size: 17, weight: .medium))
            ForEach(Array(model.insights.topics.enumerated()), id: \.offset) { _, topic in
              DisclosureGroup(topic.title) {
                VStack(alignment: .leading, spacing: 12) {
                  ForEach(topic.excerpts) { source in EvidenceRow(model: model, source: source) }
                }.padding(.vertical, 12)
              }.font(.system(size: 13)).padding(13).background(Palette.card).clipShape(
                RoundedRectangle(cornerRadius: 9))
            }
          }
          Text(
            "Пункты связаны с исходной речью. Проверьте классификацию AI по отметке времени; имена и сроки можно уточнить в задачах."
          )
          .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
        }
        if let issues = model.selected?.issues, !issues.isEmpty {
          DisclosureGroup("Замечания к записи · \(issues.count)") {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
              Text(issue).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            }
          }.foregroundStyle(.orange).font(.system(size: 12))
        }
      }.padding(22)
    }
  }
  private func evidenceSection(
    _ title: String, icon: String, sources: [SourceExcerpt], empty: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(title, systemImage: icon).font(.system(size: 17, weight: .medium))
      if sources.isEmpty { Text(empty).font(.system(size: 12)).foregroundStyle(Palette.muted) }
      ForEach(sources) { source in EvidenceRow(model: model, source: source) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
struct BriefView: View {
  @ObservedObject var model: AppModel
  let brief: MeetingBrief
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("ГЛАВНОЕ").font(.system(size: 10, weight: .semibold)).tracking(1.2)
          .foregroundStyle(Palette.muted)
        Spacer()
        SummaryCopyButton(model: model)
      }
      Text(brief.introduction).font(.system(size: 20, weight: .semibold)).lineSpacing(5)
        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      Divider()
      VStack(spacing: 0) {
        ForEach(Array(brief.points.enumerated()), id: \.offset) { _, point in
          pointView(point)
        }
      }
      if !brief.nextSteps.isEmpty {
        HStack(spacing: 10) {
          IconTile(symbol: "checklist", color: Palette.cyan, size: 32)
          Text("Ближайшие действия").font(.system(size: 17, weight: .semibold))
          Spacer()
          StatusBadge(text: "\(brief.nextSteps.count)", color: Palette.cyan)
        }
        VStack(spacing: 12) {
          ForEach(Array(brief.nextSteps.enumerated()), id: \.offset) { _, point in
            pointView(point, actionable: true)
          }
        }
      }
      HStack {
        Button {
          model.selectedTab = .tasks
        } label: {
          Label("Открыть список задач", systemImage: "checklist")
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(SurfaceButtonStyle())
        Spacer()
        StatusBadge(
          text: brief.generation?.configuration.label ?? "Локально · Qwen", symbol: "sparkles",
          color: Palette.muted)
      }
      Text(
        "Резюме подготовлено AI. По отметке времени можно сверить формулировку с исходной речью."
      )
      .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func pointView(_ point: BriefPoint, actionable: Bool = false) -> some View {
    let added = model.workspace.tasks.contains(where: { $0.title == point.taskTitle })
    return VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .top, spacing: 10) {
        Circle().fill(Palette.accent).frame(width: 6, height: 6).padding(.top, 6)
        Text(point.topic).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        if actionable {
          if added {
            StatusBadge(text: "В задачах", symbol: "checkmark", color: Palette.cyan)
          } else {
            Button {
              model.addBriefAction(point)
            } label: {
              Label("В задачи", systemImage: "plus.circle")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(SurfaceButtonStyle()).disabled(!model.workspaceReadable)
          }
        }
      }
      Text(point.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
        .foregroundStyle(Palette.muted).padding(.leading, 16)
      HStack(spacing: 7) {
        ForEach(Array(point.sources.prefix(3))) { source in
          Button {
            model.openSource(source)
          } label: {
            Label(timestamp(source.start), systemImage: "arrow.up.right")
              .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
          }.buttonStyle(SurfaceButtonStyle(bordered: false)).help("Открыть исходный фрагмент")
        }
        if point.sources.count > 3 {
          Menu("Ещё \(point.sources.count - 3)") {
            ForEach(Array(point.sources.dropFirst(3))) { source in
              Button(timestamp(source.start)) { model.openSource(source) }
            }
          }.menuStyle(.borderlessButton).fixedSize()
        }
        Spacer(minLength: 0)
      }.font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Palette.muted).padding(.leading, 16)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13)
      .overlay(alignment: .bottom) { Divider().opacity(0.6) }
  }
}

/// A contextual task rail; edits use the same persistence flow as the full task board.
struct MeetingActionPanel: View {
  @ObservedObject var model: AppModel
  let meeting: Meeting
  @State private var editing: MeetingTask?
  private var tasks: [MeetingTask] { model.workspace.tasks.filter { !$0.isComplete } }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("План действий").font(.system(size: 17, weight: .semibold))
        Spacer(minLength: 6)
        StatusBadge(text: "\(tasks.count)", color: Palette.muted)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          if tasks.isEmpty {
            Text(
              model.workspace.tasks.isEmpty
                ? "Добавьте задачу или перенесите действие из резюме." : "Все задачи выполнены."
            )
            .font(.system(size: 12)).lineSpacing(5).foregroundStyle(Palette.muted)
            .padding(.vertical, 12)
          }
          ForEach(tasks) { task in
            HStack(alignment: .top, spacing: 9) {
              Button {
                model.toggleTask(task, meetingID: meeting.id)
              } label: {
                Image(systemName: "square").font(.system(size: 19))
                  .frame(width: 30, height: 30).contentShape(Rectangle())
              }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                .accessibilityLabel("Выполнить: \(task.title)")
              Button {
                editing = task
              } label: {
                VStack(alignment: .leading, spacing: 6) {
                  Text(task.title).font(.system(size: 13, weight: .medium)).lineSpacing(3)
                    .foregroundStyle(Palette.text)
                  Text(
                    [task.assignee, task.dueText].filter { !$0.isEmpty }.joined(separator: " · ")
                  )
                  .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
              }.buttonStyle(.plain).multilineTextAlignment(.leading).help("Редактировать задачу")
            }.padding(.bottom, 16).overlay(alignment: .bottom) { Divider() }
          }
        }
      }
      Button {
        editing = MeetingTask(title: "")
      } label: {
        Label("Добавить задачу", systemImage: "plus")
          .font(.system(size: 12, weight: .medium))
          .frame(maxWidth: .infinity, minHeight: 40).contentShape(Rectangle())
      }.buttonStyle(SurfaceButtonStyle()).disabled(!model.workspaceReadable)
      Button {
        model.selectedTab = .tasks
      } label: {
        Label("Все задачи встречи", systemImage: "arrow.right")
          .font(.system(size: 11)).frame(maxWidth: .infinity, minHeight: 30).contentShape(
            Rectangle())
      }.buttonStyle(.plain).foregroundStyle(Palette.muted)
      Text("Проверьте исполнителей и сроки перед выполнением.")
        .font(.system(size: 10)).lineSpacing(3).foregroundStyle(Palette.muted)
    }.padding(18).frame(maxHeight: .infinity).panelSurface(cornerRadius: 13)
      .sheet(item: $editing) { task in
        TaskEditor(task: task) { model.saveTask($0, meetingID: meeting.id) }
      }
  }
}
struct EvidenceRow: View {
  @ObservedObject var model: AppModel
  let source: SourceExcerpt
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(source.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
      Button {
        model.openSource(source)
      } label: {
        Label("\(timestamp(source.start)) · \(source.source.label)", systemImage: "arrow.up.right")
          .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(
            Palette.highlight
          )
          .padding(.horizontal, 9).padding(.vertical, 7).contentShape(Rectangle())
      }.buttonStyle(SurfaceButtonStyle(bordered: false)).help("Перейти к исходной реплике")
    }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
      .panelSurface(tint: Palette.violet, cornerRadius: 13)
  }
}

struct TaskEditor: View {
  private enum Field: Hashable { case title, assignee, due }
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: Field?
  @State var task: MeetingTask
  let save: (MeetingTask) -> Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        IconTile(symbol: "checklist", color: Palette.cyan, size: 42)
        VStack(alignment: .leading, spacing: 4) {
          Text("Задача").font(.system(size: 22, weight: .semibold, design: .rounded))
          Text("Что сделать, кто отвечает и к какому сроку")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 7) {
            Text("Что нужно сделать").font(.system(size: 11, weight: .medium))
              .foregroundStyle(Palette.muted)
            TextField("Опишите следующий шаг", text: $task.title, axis: .vertical)
              .lineLimit(2...4).accessibilityLabel("Что нужно сделать")
              .focused($focusedField, equals: .title)
              .padding(11).panelSurface(tint: Palette.cyan, cornerRadius: 10)
              .contentShape(Rectangle())
              .simultaneousGesture(TapGesture().onEnded { focusedField = .title })
          }
          VStack(alignment: .leading, spacing: 7) {
            Text("Исполнитель · необязательно").font(.system(size: 11, weight: .medium))
              .foregroundStyle(Palette.muted)
            TextField("Имя или команда", text: $task.assignee)
              .accessibilityLabel("Исполнитель")
              .focused($focusedField, equals: .assignee)
              .padding(11).panelSurface(tint: Palette.cyan, cornerRadius: 10)
              .contentShape(Rectangle())
              .simultaneousGesture(TapGesture().onEnded { focusedField = .assignee })
          }
          VStack(alignment: .leading, spacing: 7) {
            Text("Срок · необязательно").font(.system(size: 11, weight: .medium))
              .foregroundStyle(Palette.muted)
            TextField("Например, до пятницы", text: $task.dueText)
              .accessibilityLabel("Срок задачи")
              .focused($focusedField, equals: .due)
              .padding(11).panelSurface(tint: Palette.violet, cornerRadius: 10)
              .contentShape(Rectangle())
              .simultaneousGesture(TapGesture().onEnded { focusedField = .due })
          }
          Toggle("Выполнено", isOn: $task.isComplete).toggleStyle(.checkbox)
            .font(.system(size: 12))
          if let source = task.source {
            VStack(alignment: .leading, spacing: 7) {
              Label("Из записи · \(timestamp(source.start))", systemImage: "text.bubble")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.cyan)
              Text(source.text).font(.system(size: 11)).foregroundStyle(Palette.muted)
                .lineSpacing(3).lineLimit(6).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
              .panelSurface(tint: Palette.cyan, cornerRadius: 10)
          }
        }.padding(.vertical, 2)
      }
      HStack {
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Отмена").padding(.horizontal, 17).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(SurfaceButtonStyle()).keyboardShortcut(.cancelAction)
        Button {
          if save(task) { dismiss() }
        } label: {
          Text("Сохранить").padding(.horizontal, 18).padding(.vertical, 10).contentShape(
            Rectangle())
        }.buttonStyle(SurfaceButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
          .disabled(task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.font(.system(size: 12, weight: .semibold))
    }.textFieldStyle(.plain).font(.system(size: 14)).padding(26)
      .frame(width: 520, height: 500).background(Palette.base)
  }
}
struct TaskRow: View {
  @ObservedObject var model: AppModel
  let meeting: Meeting
  let task: MeetingTask
  var showMeeting = false
  let edit: () -> Void
  var body: some View {
    HStack(alignment: .top, spacing: 13) {
      Button {
        model.toggleTask(task, meetingID: meeting.id)
      } label: {
        Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 20)).foregroundStyle(
            task.isComplete ? Palette.highlight : Palette.muted
          )
          .frame(width: 32, height: 32).contentShape(Rectangle())
      }.buttonStyle(SurfaceButtonStyle(bordered: false)).accessibilityLabel(
        task.isComplete ? "Вернуть в работу: \(task.title)" : "Выполнить: \(task.title)")
      VStack(alignment: .leading, spacing: 8) {
        Button(action: edit) {
          Text(task.title).font(.system(size: 14)).multilineTextAlignment(.leading)
            .strikethrough(task.isComplete).foregroundStyle(
              task.isComplete ? Palette.muted : .white.opacity(0.93)
            )
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("Редактировать задачу")
        if !task.assignee.isEmpty || !task.dueText.isEmpty {
          HStack(spacing: 7) {
            if !task.assignee.isEmpty {
              StatusBadge(text: task.assignee, symbol: "person", color: Palette.cyan)
                .help(task.assignee)
            }
            if !task.dueText.isEmpty {
              StatusBadge(text: task.dueText, symbol: "calendar", color: Palette.violet)
                .help(task.dueText)
            }
          }
        }
        HStack(spacing: 7) {
          if showMeeting {
            Button {
              model.select(meeting)
              model.selectedTab = .tasks
            } label: {
              Label(meeting.title, systemImage: "waveform")
                .lineLimit(1).padding(.horizontal, 8).padding(.vertical, 7).contentShape(
                  Rectangle())
            }.buttonStyle(SurfaceButtonStyle(bordered: false)).help("Открыть встречу")
          }
          if let source = task.source {
            Button {
              model.openSource(source, meeting: meeting)
            } label: {
              Label(timestamp(source.start), systemImage: "text.bubble")
                .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(SurfaceButtonStyle(bordered: false)).help("Открыть исходную реплику")
          } else {
            Text("Добавлено вручную")
          }
        }.font(.system(size: 10)).foregroundStyle(Palette.muted)
      }.frame(maxWidth: .infinity, alignment: .leading)
      Menu {
        Button("Редактировать…", action: edit)
        Button("Удалить задачу", role: .destructive) {
          model.deleteTask(task, meetingID: meeting.id)
        }
      } label: {
        Image(systemName: "ellipsis")
      }.menuStyle(.borderlessButton).frame(width: 23).accessibilityLabel("Действия с задачей")
    }.padding(15).panelSurface(
      tint: task.isComplete ? Palette.accent : Palette.cyan, cornerRadius: 13)
  }
}
struct MeetingTasksView: View {
  @ObservedObject var model: AppModel
  let meeting: Meeting
  @State private var editing: MeetingTask?
  @State private var showCompleted = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Toggle("Выполненные", isOn: $showCompleted).toggleStyle(.checkbox)
          Spacer()
          Button {
            model.export(tasksOnly: true)
          } label: {
            Label("Экспорт", systemImage: "square.and.arrow.up")
              .padding(.horizontal, 11).padding(.vertical, 9).contentShape(Rectangle())
          }.buttonStyle(SurfaceButtonStyle()).help("Экспорт задач и заметок в Markdown")
          Button {
            editing = MeetingTask(title: "")
          } label: {
            Label("Добавить задачу", systemImage: "plus")
              .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
          }.buttonStyle(SurfaceButtonStyle(prominent: true))
        }.font(.system(size: 12)).disabled(!model.workspaceReadable)
        if model.workspace.tasks.isEmpty {
          EmptyCard(
            icon: "checklist", title: "От разговора — к действию",
            text:
              "После обработки здесь появятся поручения из записи. Свои задачи можно добавить уже сейчас."
          )
        } else if !model.workspace.tasks.contains(where: { showCompleted || !$0.isComplete }) {
          EmptyCard(
            icon: "checkmark.circle", title: "Все задачи выполнены",
            text: "Включите «Выполненные», чтобы посмотреть историю.")
        }
        ForEach(model.workspace.tasks.filter { showCompleted || !$0.isComplete }) { task in
          TaskRow(model: model, meeting: meeting, task: task) { editing = task }
        }
      }.padding(20)
    }.sheet(item: $editing) { task in
      TaskEditor(task: task) { model.saveTask($0, meetingID: meeting.id) }
    }
  }
}
struct TaskBoard: View {
  @ObservedObject var model: AppModel
  @State private var query = ""
  @State private var showCompleted = false
  @State private var editing: TaskItem?
  private var items: [TaskItem] {
    model.taskItems.filter {
      (showCompleted || !$0.task.isComplete)
        && (model.projectFilter.isEmpty || $0.meeting.project == model.projectFilter)
        && (query.isEmpty
          || [$0.task.title, $0.task.assignee, $0.meeting.title].contains {
            $0.localizedCaseInsensitiveContains(query)
          })
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 13) {
        IconTile(symbol: "checklist", color: Palette.cyan, size: 44)
        VStack(alignment: .leading, spacing: 5) {
          Text("Все задачи").font(.system(size: 27, weight: .semibold, design: .rounded))
          Text("Поручения из ваших встреч в одном месте.")
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
        Spacer()
        StatusBadge(text: "\(model.openTaskCount) в работе", color: Palette.cyan)
      }
      HStack(spacing: 14) {
        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
          TextField("Задача, исполнитель или встреча", text: $query).textFieldStyle(.plain)
            .accessibilityLabel("Поиск задач")
          if !query.isEmpty {
            Button {
              query = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
                .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Очистить поиск задач")
          }
        }.padding(.horizontal, 11).frame(minHeight: 38)
          .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
        Toggle("Выполненные", isOn: $showCompleted).toggleStyle(.checkbox)
      }.font(.system(size: 12))
      ScrollView {
        LazyVStack(spacing: 10) {
          if items.isEmpty {
            emptyResults
          }
          ForEach(items) { item in
            TaskRow(model: model, meeting: item.meeting, task: item.task, showMeeting: true) {
              editing = item
            }
          }
        }
      }
    }.padding(.horizontal, 28).padding(.bottom, 22)
      .sheet(item: $editing) { item in
        TaskEditor(task: item.task) { model.saveTask($0, meetingID: item.meeting.id) }
      }
  }
  private var emptyResults: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !query.isEmpty || !model.projectFilter.isEmpty {
        EmptyCard(
          icon: "magnifyingglass", title: "Ничего не найдено",
          text:
            "Попробуйте другой запрос или сбросьте фильтры, чтобы увидеть задачи из всех встреч.")
        Button {
          query = ""
          model.projectFilter = ""
        } label: {
          Label("Сбросить фильтры", systemImage: "line.3.horizontal.decrease.circle")
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(SurfaceButtonStyle())
      } else if !model.taskItems.isEmpty && !showCompleted {
        EmptyCard(
          icon: "checkmark.circle", title: "Все задачи выполнены",
          text: "Включите «Выполненные», чтобы посмотреть задачи и вернуться к исходным встречам.")
      } else {
        EmptyCard(
          icon: "checklist", title: "Задач пока нет",
          text: "Откройте встречу и добавьте задачу вручную или перенесите действие из резюме.")
      }
    }
  }
}

struct JobStrip: View {
  @ObservedObject var model: AppModel
  let job: ProcessingJob
  private var color: Color {
    switch job.state {
    case .running: Palette.cyan
    case .queued: Palette.violet
    case .paused, .failed: .orange
    }
  }
  private var symbol: String {
    switch job.state {
    case .running: "arrow.triangle.2.circlepath"
    case .queued: "clock"
    case .paused: "pause.circle"
    case .failed: "exclamationmark.triangle"
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        if job.state == .running {
          ProgressView().controlSize(.small)
        } else {
          IconTile(symbol: symbol, color: color, size: 30)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(job.state.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
          Text(job.configuration.label).font(.system(size: 10)).foregroundStyle(Palette.muted)
            .lineLimit(1).help(job.configuration.label)
        }
        Spacer(minLength: 8)
        if job.state == .running || job.state == .queued {
          Button {
            model.pauseJob(job.id)
          } label: {
            Label("Пауза", systemImage: "pause")
              .padding(.horizontal, 11).padding(.vertical, 8).contentShape(Rectangle())
          }.buttonStyle(SurfaceButtonStyle())
        } else {
          Button {
            model.enqueue(job.id)
          } label: {
            Label(job.state == .failed ? "Повторить" : "Продолжить", systemImage: "play")
              .padding(.horizontal, 11).padding(.vertical, 8).contentShape(Rectangle())
          }.buttonStyle(SurfaceButtonStyle())
          if job.configuration != model.summaryConfiguration {
            Menu {
              Button("Продолжить с текущими настройками AI") { model.reconfigureJob(job.id) }
                .disabled(!model.canChangeMeeting(job.id))
            } label: {
              Image(systemName: "slider.horizontal.3")
                .frame(width: 28, height: 30).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Настройки обработки")
          }
        }
        Button {
          model.removeJob(job.id)
        } label: {
          Image(systemName: "xmark").frame(width: 30, height: 30).contentShape(Rectangle())
        }.buttonStyle(SurfaceButtonStyle(bordered: false))
          .help("Убрать из очереди; материалы сохранятся").accessibilityLabel("Убрать из очереди")
      }
      Text(job.message).font(.system(size: 11)).foregroundStyle(Palette.muted)
        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }.font(.system(size: 11, weight: .medium)).padding(14)
      .panelSurface(tint: color, cornerRadius: 13)
  }
}
struct ProcessingQueueView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 13) {
          IconTile(symbol: "arrow.triangle.2.circlepath", color: Palette.violet, size: 44)
          VStack(alignment: .leading, spacing: 5) {
            Text("Обработка").font(.system(size: 27, weight: .semibold, design: .rounded))
            Text("Результаты готовятся в фоне.").font(.system(size: 12)).foregroundStyle(
              Palette.muted)
          }
          Spacer()
          StatusBadge(text: "\(model.jobs.count) в очереди", color: Palette.violet)
        }
        Text(
          "Открывайте встречи, редактируйте задачи или начните новую запись. Обработка идёт по очереди; распознавание текущей речи получает приоритет."
        )
        .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(5)
        if model.jobs.isEmpty {
          EmptyCard(
            icon: "checkmark.circle", title: "Очередь свободна",
            text:
              "После остановки записи здесь появится ход обработки. Чтобы вернуться к сохранённым материалам, откройте встречу в библиотеке."
          )
        }
        ForEach(model.jobs) { job in
          VStack(alignment: .leading, spacing: 10) {
            if let meeting = model.meetings.first(where: { $0.id == job.id }) {
              Button {
                model.select(meeting)
              } label: {
                HStack {
                  IconTile(symbol: "waveform", color: Palette.violet, size: 32)
                  Text(meeting.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                  Spacer()
                  Image(systemName: "arrow.up.right")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(
                  Rectangle())
              }.buttonStyle(SurfaceButtonStyle(bordered: false)).help("Открыть встречу")
            }
            Text(job.grounded ? "Резюме, факты и темы" : "Резюме и связное изложение").font(
              .system(size: 11)
            ).foregroundStyle(Palette.muted)
            JobStrip(model: model, job: job)
          }.padding(14).panelSurface(tint: Palette.violet)
        }
        if !model.jobs.isEmpty {
          Text(
            "Готовые части сохраняются. После паузы или перезапуска обработка продолжится с сохранённого результата."
          )
          .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
      }.padding(.horizontal, 28).padding(.bottom, 24)
    }
  }
}
struct TranscriptView: View {
  @ObservedObject var model: AppModel
  @State private var query = ""
  private var rows: [TranscriptRow] {
    model.transcriptRows.filter {
      query.isEmpty || $0.utterance.text.localizedCaseInsensitiveContains(query)
    }
  }
  private var target: String? {
    guard let source = model.focusedSource else { return nil }
    return model.transcriptRows.filter { $0.source == source.source }
      .min { abs($0.utterance.start - source.start) < abs($1.utterance.start - source.start) }?.id
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Найти в расшифровке", text: $query).textFieldStyle(.roundedBorder)
        Text("\(rows.count) \(countWord(rows.count, "реплика", "реплики", "реплик"))").font(
          .system(size: 11)
        ).foregroundStyle(Palette.muted)
      }.padding(16)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if rows.isEmpty {
              EmptyCard(
                icon: "waveform", title: query.isEmpty ? "Ожидаю речь" : "Совпадений нет",
                text:
                  "Реплики появляются по ходу записи. Сохранённое аудио можно обработать через меню встречи."
              )
            }
            ForEach(rows) { row in
              VStack(alignment: .leading, spacing: 8) {
                Text("\(timestamp(row.utterance.start)) · \(row.source.label)")
                  .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(
                    Palette.highlight)
                Text(row.utterance.text).font(.system(size: 14)).lineSpacing(5).textSelection(
                  .enabled)
              }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(
                  row.id == target ? Palette.accent.opacity(0.12) : Palette.card.opacity(0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8)).id(row.id)
            }
          }.padding(.horizontal, 16).padding(.bottom, 16)
        }.onAppear { if let target { proxy.scrollTo(target, anchor: .center) } }
          .onChange(of: target) { _, value in
            if let value {
              query = ""
              proxy.scrollTo(value, anchor: .center)
            }
          }
      }
    }
  }
}
struct MeetingNotesView: View {
  @ObservedObject var model: AppModel
  let meetingID: UUID
  @State private var draft = ""
  @State private var saved = ""
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text("Личные заметки").font(.system(size: 17, weight: .medium))
          Spacer()
          Text(draft == saved ? "Сохранено" : "Есть изменения").font(.system(size: 11))
            .foregroundStyle(Palette.muted)
          Button("Сохранить") { save() }.disabled(!model.workspaceReadable || draft == saved)
        }
        TextEditor(text: $draft).font(.system(size: 14)).scrollContentBackground(.hidden)
          .frame(minHeight: 150).padding(10).background(Palette.base).clipShape(
            RoundedRectangle(cornerRadius: 8)
          )
          .disabled(!model.workspaceReadable).accessibilityLabel("Личные заметки")
        Text("Заметки сохраняются автоматически и входят в экспорт Markdown.").font(
          .system(size: 10)
        ).foregroundStyle(Palette.muted)
        Divider()
        Text("Метки и контекст записи").font(.system(size: 17, weight: .medium))
        if model.notes.isEmpty {
          Text("На панели записи можно отметить важный момент.").font(.system(size: 12))
            .foregroundStyle(Palette.muted)
        }
        ForEach(model.notes) { note in
          VStack(alignment: .leading, spacing: 8) {
            Text("\(timestamp(note.time)) · \(note.kind)").font(.system(size: 11)).foregroundStyle(
              Palette.highlight)
            Text(note.text).font(.system(size: 13)).textSelection(.enabled)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
      }.padding(20)
    }.onAppear {
      draft = model.workspace.personalNotes
      saved = draft
    }
    .onChange(of: draft) { _, _ in if draft != saved { save() } }
    .onDisappear { if draft != saved { save() } }
  }
  private func save() {
    if model.savePersonalNotes(draft, meetingID: meetingID) { saved = draft }
  }
}
struct RenameMeetingView: View {
  private enum Field: Hashable { case title, project }
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: Field?
  @ObservedObject var model: AppModel
  let meeting: Meeting
  @State private var title = ""
  @State private var project = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        IconTile(symbol: "pencil", color: Palette.violet, size: 42)
        VStack(alignment: .leading, spacing: 4) {
          Text("Название и проект").font(.system(size: 22, weight: .semibold, design: .rounded))
          Text("Помогут быстрее найти встречу в библиотеке")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("Название встречи").font(.system(size: 11, weight: .medium))
          .foregroundStyle(Palette.muted)
        TextField("Название встречи", text: $title, axis: .vertical).lineLimit(1...3)
          .accessibilityLabel("Название встречи")
          .focused($focusedField, equals: .title)
          .padding(11).panelSurface(tint: Palette.violet, cornerRadius: 10)
          .contentShape(Rectangle())
          .simultaneousGesture(TapGesture().onEnded { focusedField = .title })
      }
      VStack(alignment: .leading, spacing: 7) {
        Text("Проект · необязательно").font(.system(size: 11, weight: .medium))
          .foregroundStyle(Palette.muted)
        TextField("Например, название клиента", text: $project)
          .accessibilityLabel("Проект встречи")
          .focused($focusedField, equals: .project)
          .padding(11).panelSurface(tint: Palette.violet, cornerRadius: 10)
          .contentShape(Rectangle())
          .simultaneousGesture(TapGesture().onEnded { focusedField = .project })
      }
      HStack {
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Отмена").padding(.horizontal, 17).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(SurfaceButtonStyle()).keyboardShortcut(.cancelAction)
        Button {
          if model.rename(meeting, title: title, project: project) { dismiss() }
        } label: {
          Text("Сохранить").padding(.horizontal, 18).padding(.vertical, 10).contentShape(
            Rectangle())
        }
        .buttonStyle(SurfaceButtonStyle(prominent: true))
        .keyboardShortcut(.defaultAction).disabled(
          title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }.font(.system(size: 12, weight: .semibold))
    }.textFieldStyle(.plain).font(.system(size: 14)).padding(26).frame(width: 520)
      .background(Palette.base)
      .onAppear {
        title = meeting.title
        project = meeting.project ?? ""
      }
  }
}

func countWord(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
  let value = abs(count) % 100
  if (11...14).contains(value) { return many }
  switch value % 10 {
  case 1: return one
  case 2...4: return few
  default: return many
  }
}
