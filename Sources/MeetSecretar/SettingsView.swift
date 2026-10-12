import MeetingCore
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var apiKey = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 12) {
        IconTile(symbol: "slider.horizontal.3", color: Palette.violet, size: 42)
        VStack(alignment: .leading, spacing: 4) {
          Text("Настройки").font(.system(size: 23, weight: .semibold, design: .rounded))
          Text("Запись, AI и ваши материалы").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Готово").font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 10).contentShape(Rectangle())
        }.buttonStyle(SurfaceButtonStyle(prominent: true)).keyboardShortcut(.cancelAction)
      }
      SelectionTabs(
        label: "Раздел настроек", choices: SettingsSection.allCases,
        selection: $model.settingsSection, title: { $0.rawValue })
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          switch model.settingsSection {
          case .recording: captureSettings
          case .storage: storageSettings
          case .summary: summarySettings
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
          .panelSurface(tint: model.settingsSection == .summary ? Palette.violet : Palette.cyan)
      }
      Text("Изменения сохраняются автоматически. API-ключ — кнопкой «Сохранить ключ».")
        .font(.system(size: 11)).foregroundStyle(Palette.muted)
    }.padding(24).frame(width: 650, height: 580).background(Palette.base)
      .foregroundStyle(.white.opacity(0.93)).preferredColorScheme(.dark).tint(Palette.highlight)
      .onDisappear { apiKey = "" }
  }

  private var summarySettings: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Где создавать резюме").font(.system(size: 17, weight: .medium))
      SelectionTabs(
        label: "Способ создания резюме", choices: SummaryProvider.allCases,
        selection: $model.summaryProvider, title: { $0.label })
      Text(
        model.summaryProvider == .local
          ? "Речь и резюме обрабатываются локально. Интернет и API-ключ не нужны."
          : "Речь распознаётся на Mac. Для резюме название, проект и расшифровка отправляются в OpenAI. Аудио, видео и личные заметки не отправляются."
      )
      .font(.system(size: 13)).lineSpacing(4).foregroundStyle(Palette.muted)
      if model.summaryProvider == .local {
        Picker("Подробность протокола", selection: $model.fastProcessing) {
          Text("Резюме и исходные реплики").tag(true)
          Text("Также отредактировать полное обсуждение").tag(false)
        }
      }
      Divider()
      HStack {
        Label("Подключение OpenAI", systemImage: "network").font(.system(size: 16, weight: .medium))
        Spacer()
        Text(model.hasOpenAIKey ? "Ключ сохранён" : "Ключ не добавлен")
          .font(.system(size: 11)).foregroundStyle(
            model.hasOpenAIKey ? Palette.highlight : Palette.muted)
      }
      SecureField(
        model.hasOpenAIKey ? "Новый API-ключ для замены" : "API-ключ OpenAI", text: $apiKey
      )
      .textFieldStyle(.roundedBorder).accessibilityLabel("API-ключ OpenAI")
      HStack {
        Button("Сохранить ключ") {
          if model.saveAPIKey(apiKey) { apiKey = "" }
        }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button(model.checkingOpenAI ? "Проверяю…" : "Проверить и загрузить модели") {
          Task { await model.checkOpenAI() }
        }.disabled(!model.hasOpenAIKey || model.checkingOpenAI)
        Spacer()
        if model.hasOpenAIKey {
          Button("Удалить ключ", role: .destructive) {
            model.removeAPIKey()
            apiKey = ""
          }
        }
      }.font(.system(size: 12))
      if !model.openAIStatus.isEmpty {
        Text(model.openAIStatus).font(.system(size: 12)).foregroundStyle(Palette.highlight)
      }
      if let error = model.openAIError {
        Text(error).font(.system(size: 12)).foregroundStyle(.orange).lineSpacing(4)
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Модель для резюме").font(.system(size: 13, weight: .medium))
        HStack {
          TextField("Введите ID модели или выберите из списка", text: $model.openAIModel)
            .textFieldStyle(.roundedBorder).accessibilityLabel("Модель OpenAI")
          Menu("Выбрать") {
            ForEach(model.availableOpenAIModels, id: \.self) { id in
              Button(id) { model.openAIModel = id }
            }
          }.disabled(model.availableOpenAIModels.isEmpty)
        }
        Text(
          "Список берётся из вашего аккаунта. Нужна текстовая модель с Responses API и Structured Outputs; доступность зависит от API-ключа."
        )
        .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
      }
      HStack {
        Link("Создать API-ключ", destination: URL(string: "https://platform.openai.com/api-keys")!)
        Spacer()
        Link(
          "Баланс и расходы API",
          destination: URL(
            string: "https://platform.openai.com/settings/organization/billing/overview")!)
      }.font(.system(size: 12))
      Text(
        "Ключ хранится в Связке ключей macOS. Использование API оплачивается отдельно от подписки ChatGPT. Проверка ключа загружает только список моделей."
      )
      .font(.system(size: 11)).lineSpacing(4).foregroundStyle(Palette.muted)
    }
  }

  private var captureSettings: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("Распознавание речи всегда локальное", systemImage: "waveform")
        .font(.system(size: 16, weight: .medium))
      Text(
        "Выберите, откуда записывать разговор. Для очной встречи достаточно микрофона."
      )
      .font(.system(size: 12)).lineSpacing(4).foregroundStyle(Palette.muted)
      CaptureModeView(model: model)
      HStack {
        Text("Микрофон")
        Spacer()
        Text(model.microphoneAllowed ? "Разрешён" : "Нужен доступ").foregroundStyle(
          model.microphoneAllowed ? Palette.text : .orange)
        Button("Настроить") { Task { await model.requestMicrophone() } }
      }
      HStack {
        Text("Экран и системное аудио")
        Spacer()
        Text(
          model.captureSystemAudio ? model.screenAccess.label : "Не требуется"
        )
        .foregroundStyle(
          model.screenAllowed
            ? Palette.text : (model.captureSystemAudio ? .orange : Palette.muted))
      }
      if model.captureSystemAudio {
        if let detail = model.screenAccess.detail {
          Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3)
        }
        HStack {
          Button("Проверить доступ") { Task { await model.refreshDisplays() } }
            .disabled(model.screenAccess == .checking)
          Button("Настройки macOS") { model.openPrivacy("Privacy_ScreenCapture") }
        }
      }
      Divider()
      Picker("Микрофон", selection: $model.microphoneID) {
        Text("Системный по умолчанию").tag(String?.none)
        ForEach(model.microphones, id: \.uniqueID) {
          Text($0.localizedName).tag(Optional($0.uniqueID))
        }
      }
      if model.captureSystemAudio {
        HStack {
          Picker("Экран", selection: $model.displayID) {
            Text("Основной экран").tag(UInt32?.none)
            ForEach(model.displays, id: \.displayID) {
              Text("Экран \($0.displayID) · \($0.width) × \($0.height)").tag(Optional($0.displayID))
            }
          }
          Button("Обновить") { Task { await model.refreshDisplays() } }
        }
        Toggle("Сохранять видео экрана", isOn: $model.recordScreen)
        Toggle("Сохранять текст со слайдов и экрана", isOn: $model.useOCR)
        DisclosureGroup("Если доступ включён, но запись не начинается") {
          VStack(alignment: .leading, spacing: 12) {
            Text(
              "После обновления macOS может потребовать разрешить захват для новой сборки и перезапустить приложение."
            )
            Button("Повторно запросить доступ к экрану") {
              Task { await model.renewScreenPermission() }
            }
          }.font(.system(size: 12)).padding(.top, 10)
        }
      }
    }.font(.system(size: 13)).disabled(model.isRecording || model.isStarting)
  }

  private var storageSettings: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("Ваши встречи на этом Mac", systemImage: "externaldrive").font(
        .system(size: 17, weight: .medium))
      Text(
        "Записи, полная расшифровка, резюме и задачи сохраняются в библиотеке приложения. Экспорт объединяет протокол и ваши заметки в Markdown."
      )
      .font(.system(size: 13)).lineSpacing(5)
      Button("Открыть папку встреч") { model.revealLibrary() }
      Text(
        "Удаление встречи перемещает её материалы в Корзину macOS. Экспортированные файлы сохраняются."
      )
      .font(.system(size: 12)).lineSpacing(4).foregroundStyle(Palette.muted)
    }
  }
}

struct CaptureModeView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      SelectionTabs(
        label: "Источники записи", choices: [false, true],
        selection: $model.captureSystemAudio,
        title: { $0 ? "Микрофон + звук Mac" : "Только микрофон" })
      Text(
        model.captureSystemAudio
          ? "Голос и звук приложений. Для этого режима нужен доступ к экрану и системному аудио."
          : "Ваш голос и разговор рядом с Mac. Доступ к экрану не нужен."
      )
      .font(.system(size: 11)).lineSpacing(3).foregroundStyle(Palette.muted)
      if model.captureSystemAudio && !model.screenAllowed {
        Button("Записывать без доступа к экрану") { model.captureSystemAudio = false }
          .font(.system(size: 12))
      }
    }
  }
}

struct SummaryModeView: View {
  @ObservedObject var model: AppModel
  var compact = false
  var body: some View {
    if compact {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Image(systemName: "sparkles").foregroundStyle(Palette.violet)
          Text("Следующее резюме:").foregroundStyle(Palette.muted)
          Picker("Способ создания резюме", selection: $model.summaryProvider) {
            ForEach(SummaryProvider.allCases, id: \.self) { provider in
              Text(provider.label).tag(provider)
            }
          }.labelsHidden().frame(width: 124)
            .accessibilityLabel("Способ создания следующего резюме")
          Spacer(minLength: 4)
          Button {
            openSettings()
          } label: {
            Label("Настроить AI", systemImage: "slider.horizontal.3")
              .padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
          }.buttonStyle(SurfaceButtonStyle(bordered: false))
        }.font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 3)
          .background(Palette.violet.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
          .help(
            model.summaryProvider == .local
              ? "Новое резюме будет создано на Mac"
              : "Название, проект и расшифровка отправятся в OpenAI. Аудио и видео останутся на Mac."
          )
        if !model.summaryReady {
          Text("Для резюме через OpenAI добавьте API-ключ и выберите модель в настройках.")
            .font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 10)
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          IconTile(symbol: "sparkles", color: Palette.violet, size: 30)
          Text("Резюме").font(.system(size: 12, weight: .medium))
          SelectionTabs(
            label: "Способ создания резюме", choices: SummaryProvider.allCases,
            selection: $model.summaryProvider, title: { $0 == .local ? "На Mac" : "OpenAI API" }
          )
          .frame(width: 230)
          Spacer(minLength: 8)
          Button {
            openSettings()
          } label: {
            Image(systemName: "slider.horizontal.3").frame(width: 32, height: 32).contentShape(
              Rectangle())
          }.buttonStyle(SurfaceButtonStyle()).accessibilityLabel("Настроить AI").help(
            "Настроить резюме и OpenAI")
        }
        Text(
          model.summaryProvider == .local
            ? "Распознавание и резюме остаются на вашем Mac."
            : model.summaryReady
              ? "Текст расшифровки → OpenAI · \(model.openAIModel)"
              : "Добавьте API-ключ и выберите модель в настройках. Записывать встречи можно уже сейчас."
        )
        .font(.system(size: 11)).foregroundStyle(model.summaryReady ? Palette.muted : .orange)
        .lineSpacing(3)
      }.padding(14).panelSurface(tint: Palette.violet)
    }
  }
  private func openSettings() {
    model.settingsSection = .summary
    model.showSettings = true
  }
}
