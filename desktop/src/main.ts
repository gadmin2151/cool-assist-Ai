import {
  app,
  BrowserWindow,
  ipcMain,
  dialog,
  shell,
  safeStorage,
  session,
  desktopCapturer,
  powerSaveBlocker,
} from "electron";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import {
  DEFAULT_SETTINGS,
  type Meeting,
  type RecordingOptions,
  type Settings,
  type TaskItem,
} from "./contracts";
import { MeetingStore, atomicJSON } from "./core/store";
import { OpenAIClient } from "./core/openai";
import { LocalAIClient } from "./core/local-ai";
import { LocalModels, runtimeExecutable } from "./core/models";
import { ProcessingQueue } from "./core/queue";
import { markdown } from "./core/markdown";
import * as validate from "./core/validation";

app.setName("Cool Assist Ai");
if (!app.isPackaged && process.env.COOL_ASSIST_TEST_DATA)
  app.setPath("userData", path.resolve(process.env.COOL_ASSIST_TEST_DATA));
const primaryInstance = app.requestSingleInstanceLock();
if (!primaryInstance) app.quit();
let window: BrowserWindow;
let store: MeetingStore;
let queue: ProcessingQueue;
let localModels: LocalModels;
let closing = false;
let blocker: number | undefined;
let currentKey = "";
let encryptedKey: string | undefined;
let preferences: Settings = { ...DEFAULT_SETTINGS };
let normalBounds: Electron.Rectangle | undefined;
let compact = false;
const rendererFile = path.join(__dirname, "ui/index.html");
const rendererURL = pathToFileURL(rendererFile).href;
const userData = () => app.getPath("userData");
const secureStorage = () =>
  safeStorage.isEncryptionAvailable() &&
  (process.platform !== "linux" ||
    safeStorage.getSelectedStorageBackend() !== "basic_text");
const changed = () => {
  if (window && !window.isDestroyed()) window.webContents.send("updated");
};
const saveConfig = () =>
  atomicJSON(path.join(userData(), "settings.json"), {
    settings: preferences,
    encryptedKey,
  });
function unblocked(): void {
  if (blocker !== undefined && powerSaveBlocker.isStarted(blocker))
    powerSaveBlocker.stop(blocker);
  blocker = undefined;
}
function handle(channel: string, fn: (...args: never[]) => unknown): void {
  ipcMain.handle(channel, async (event, ...args: unknown[]) => {
    if (
      !window ||
      event.sender !== window.webContents ||
      event.senderFrame?.url !== rendererURL
    )
      throw new Error("Запрос отклонён.");
    return fn(...(args as never[]));
  });
}
if (primaryInstance)
  void app
    .whenReady()
    .then(() => {
      fs.mkdirSync(userData(), { recursive: true, mode: 0o700 });
      const configFile = path.join(userData(), "settings.json");
      if (fs.existsSync(configFile)) {
        try {
          const config = JSON.parse(fs.readFileSync(configFile, "utf8")) as {
            settings: Settings;
            encryptedKey?: string;
          };
          preferences = validate.settings(config.settings);
          encryptedKey = config.encryptedKey;
          if (encryptedKey && secureStorage())
            currentKey = safeStorage.decryptString(
              Buffer.from(encryptedKey, "base64"),
            );
        } catch {
          /* Keep the original file. The settings UI shows no usable key and allows replacement. */
        }
      }
      store = new MeetingStore(path.join(userData(), "Meetings"));
      const api = new OpenAIClient(() => currentKey);
      localModels = new LocalModels(path.join(userData(), "Models"), changed);
      const local = new LocalAIClient(() => {
        const runtime = app.isPackaged
          ? path.join(process.resourcesPath, "native")
          : path.join(
              __dirname,
              "../runtime",
              `${process.platform === "win32" ? "win" : process.platform}-${process.arch}`,
            );
        const darwin = !app.isPackaged && process.platform === "darwin";
        return {
          ...localModels.paths(),
          temporaryRoot: path.join(userData(), "Inference"),
          whisperExecutable: darwin
            ? path.resolve(
                __dirname,
                "../../vendor/whisper.cpp/build/bin/whisper-cli",
              )
            : runtimeExecutable(
                path.join(runtime, "whisper"),
                process.platform === "win32"
                  ? "whisper-cli.exe"
                  : "whisper-cli",
              ),
          llamaExecutable: darwin
            ? path.resolve(
                __dirname,
                "../../vendor/llama/llama-b10844/llama-completion",
              )
            : runtimeExecutable(
                path.join(runtime, "llama"),
                process.platform === "win32"
                  ? "llama-completion.exe"
                  : "llama-completion",
              ),
        };
      });
      const enabled = (settings: Settings) =>
        settings.provider === "local"
          ? localModels.state().ready
          : Boolean(currentKey) &&
            preferences.cloudConsent &&
            settings.cloudConsent;
      queue = new ProcessingQueue(
        store,
        {
          transcribe: (audio, settings, previous, signal) =>
            (settings.provider === "local" ? local : api).transcribe(
              audio,
              settings,
              previous,
              signal,
            ),
          brief: (input, meeting, signal) =>
            (meeting.settings.provider === "local" ? local : api).brief(
              input,
              meeting,
              signal,
            ),
        },
        enabled,
        changed,
      );
      window = new BrowserWindow({
        width: 1360,
        height: 900,
        minWidth: 900,
        minHeight: 640,
        backgroundColor: "#202123",
        title: "Cool Assist Ai",
        icon: path.join(__dirname, "ui/logo.svg"),
        show: false,
        webPreferences: {
          preload: path.join(__dirname, "preload.cjs"),
          contextIsolation: true,
          nodeIntegration: false,
          sandbox: true,
          webSecurity: true,
          backgroundThrottling: false,
        },
      });
      window.setMenuBarVisibility(false);
      window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
      window.webContents.on("will-navigate", (event, url) => {
        if (url !== rendererURL) event.preventDefault();
      });
      const systemCaptureAllowed = () =>
        process.platform === "win32" &&
        Boolean(store.activeID) &&
        store.get(store.activeID!).source === "microphone+system";
      session.defaultSession.setPermissionRequestHandler(
        (webContents, permission, callback, details) => {
          const allowed =
            webContents === window.webContents &&
            details.requestingUrl === rendererURL;
          const mediaTypes =
            "mediaTypes" in details ? details.mediaTypes : undefined;
          callback(
            allowed &&
              ((permission === "media" &&
                Array.isArray(mediaTypes) &&
                mediaTypes.length > 0 &&
                mediaTypes.every((type: unknown) => type === "audio")) ||
                (permission === "display-capture" && systemCaptureAllowed())),
          );
        },
      );
      session.defaultSession.setPermissionCheckHandler(
        (webContents, permission, _origin, details) =>
          webContents === window.webContents &&
          window.webContents.getURL() === rendererURL &&
          details.isMainFrame &&
          ((permission === "media" && details.mediaType === "audio") ||
            (permission === "display-capture" && systemCaptureAllowed())),
      );
      session.defaultSession.setDisplayMediaRequestHandler(
        async (request, callback) => {
          if (
            process.platform !== "win32" ||
            request.frame?.url !== rendererURL ||
            !store.activeID ||
            store.get(store.activeID).source !== "microphone+system"
          ) {
            callback({});
            return;
          }
          try {
            const screens = await desktopCapturer.getSources({
              types: ["screen"],
              thumbnailSize: { width: 0, height: 0 },
            });
            const screen = screens[0];
            if (!screen) {
              callback({});
              return;
            }
            callback({ video: screen, audio: "loopback" });
          } catch {
            callback({});
          }
        },
      );
      handle("snapshot", () => ({
        meetings: store.list(),
        settings: preferences,
        localModels: localModels.state(),
        hasKey: Boolean(currentKey),
        persistentKey: Boolean(encryptedKey),
        secureStorage: secureStorage(),
        activeID: store.activeID,
        platform: process.platform,
        version: app.getVersion(),
      }));
      handle("meeting", (meetingID: string) => store.inspect(meetingID));
      handle("record:start", (options: RecordingOptions) => {
        if (typeof options?.systemAudio !== "boolean")
          throw new Error("Выберите источник записи.");
        if (options.systemAudio && process.platform !== "win32")
          throw new Error(
            "Выберите микрофон или монитор аудиоустройства в системе.",
          );
        const m = store.create(
          {
            title: validate.text(options.title, 200),
            project: validate.text(options.project, 200),
            systemAudio: options.systemAudio,
          },
          preferences,
        );
        blocker = powerSaveBlocker.start("prevent-app-suspension");
        changed();
        return m;
      });
      handle("record:append", (meetingID: string, samples: ArrayBuffer) => {
        if (!(samples instanceof ArrayBuffer))
          throw new Error("Некорректный аудиобуфер.");
        const previous = store.get(meetingID).duration;
        store.append(meetingID, Buffer.from(samples));
        if (store.get(meetingID).duration !== previous) changed();
      });
      handle("record:pause", (meetingID: string, paused: boolean) => {
        if (typeof paused !== "boolean") throw new Error("Некорректный режим.");
        store.pause(meetingID, paused);
        changed();
      });
      handle("record:stop", (meetingID: string) => {
        store.stop(meetingID);
        unblocked();
        changed();
      });
      handle("record:mark", (meetingID: string) => {
        const m = store.get(meetingID);
        if (store.activeID !== meetingID) throw new Error("Запись не активна.");
        m.bookmarks.push(store.elapsed(meetingID));
        store.save(m);
        changed();
      });
      handle("queue", (meetingID: string, action: string) => {
        const m = store.get(meetingID);
        if (action === "pause") {
          queue.pause(meetingID);
          return;
        }
        if (!["resume", "summarize"].includes(action))
          throw new Error("Неизвестное действие.");
        if (!enabled(preferences))
          throw new Error(
            preferences.provider === "local"
              ? "Скачайте локальные модели в настройках."
              : "Добавьте API-ключ и разрешите обработку в OpenAI в настройках.",
          );
        if (queue.busy(meetingID))
          throw new Error("Обработка уже выполняется.");
        if (action === "summarize" && store.activeID === meetingID)
          throw new Error("Сначала завершите запись.");
        // Explicit retry uses visible current settings; recognized source text remains intact.
        m.settings = { ...preferences };
        queue.resume(meetingID);
      });
      handle(
        "meeting:save",
        (
          meetingID: string,
          patch: {
            title?: string;
            project?: string;
            notes?: string;
            tasks?: TaskItem[];
          },
        ) => {
          const m = store.get(meetingID);
          if (!patch || typeof patch !== "object")
            throw new Error("Некорректное изменение.");
          if (patch.title !== undefined)
            m.title = validate.text(patch.title, 200).trim() || "Встреча";
          if (patch.project !== undefined)
            m.project = validate.text(patch.project, 200);
          if (patch.notes !== undefined)
            m.notes = validate.text(patch.notes, 200000);
          if (patch.tasks !== undefined) m.tasks = validate.tasks(patch.tasks);
          store.save(m);
          changed();
        },
      );
      handle(
        "task:done",
        (meetingID: string, taskID: string, done: boolean) => {
          if (typeof done !== "boolean")
            throw new Error("Некорректное состояние задачи.");
          const m = store.get(meetingID);
          const key = validate.id(taskID);
          const item = m.tasks.find((task) => task.id === key);
          if (!item) throw new Error("Задача не найдена.");
          item.done = done;
          store.save(m);
          changed();
        },
      );
      handle("meeting:remove", async (meetingID: string) => {
        const m = store.inspect(meetingID);
        if (store.activeID === meetingID || queue.busy(meetingID))
          throw new Error(
            "Сначала остановите запись или приостановите обработку.",
          );
        const answer = await dialog.showMessageBox(window, {
          type: "question",
          message: `Удалить «${m.title}»?`,
          detail:
            "Встреча и её аудио будут перемещены в Корзину. Экспортированные файлы сохранятся.",
          buttons: ["Отмена", "В Корзину"],
          defaultId: 0,
          cancelId: 0,
        });
        if (answer.response !== 1) return;
        if (!store.isDamaged(meetingID)) queue.pause(meetingID);
        await shell.trashItem(store.directory(meetingID));
        store.forget(meetingID);
        changed();
      });
      handle("meeting:export", async (meetingID: string) => {
        const m = store.get(meetingID);
        const name = m.title
          .replace(/[<>:"/\\|?*\x00-\x1f]/g, "_")
          .slice(0, 120);
        const choice = await dialog.showSaveDialog(window, {
          defaultPath: `${name}.md`,
          filters: [{ name: "Markdown", extensions: ["md"] }],
        });
        if (choice.canceled || !choice.filePath) return false;
        fs.writeFileSync(choice.filePath, markdown(m), { mode: 0o600 });
        return true;
      });
      handle("settings:save", (value: Settings) => {
        preferences = validate.settings(value);
        if (!preferences.cloudConsent) queue.revokeConsent();
        saveConfig();
        changed();
      });
      handle("key:save", (key: string, persist: boolean) => {
        const value = validate.text(key, 512).trim();
        if (!/^[!-~]{8,512}$/.test(value) || typeof persist !== "boolean")
          throw new Error("Введите действительный API-ключ.");
        if (persist && !secureStorage())
          throw new Error(
            "Защищённое хранилище ОС недоступно. Используйте ключ только до закрытия приложения или настройте Secret Service.",
          );
        const encrypted = persist
          ? safeStorage.encryptString(value).toString("base64")
          : undefined;
        encryptedKey = encrypted;
        currentKey = value;
        saveConfig();
        changed();
      });
      handle("key:remove", () => {
        queue.revokeConsent();
        currentKey = "";
        encryptedKey = undefined;
        saveConfig();
        changed();
      });
      handle("local:download", () => localModels.start());
      handle("local:cancel", () => localModels.cancel());
      handle("models", () => api.models(AbortSignal.timeout(120000)));
      handle("compact", (enabled: boolean) => {
        if (typeof enabled !== "boolean")
          throw new Error("Некорректный режим окна.");
        if (enabled && !compact) {
          normalBounds = window.getBounds();
          window.setMinimumSize(520, 148);
          window.setSize(600, 170);
          window.setAlwaysOnTop(true, "floating");
        }
        if (!enabled && compact) {
          window.setAlwaysOnTop(false);
          window.setMinimumSize(900, 640);
          if (normalBounds) window.setBounds(normalBounds);
        }
        compact = enabled;
      });
      window.on("close", (event) => {
        if (closing) return;
        event.preventDefault();
        void (async () => {
          if (store.activeID) {
            const response = await dialog.showMessageBox(window, {
              type: "question",
              message: "Завершить запись и выйти?",
              detail:
                "Аудио сохранится. Незавершённую обработку можно продолжить после запуска.",
              buttons: ["Продолжить запись", "Сохранить и выйти"],
              defaultId: 0,
              cancelId: 0,
            });
            if (response.response !== 1) return;
            window.webContents.send("command", "stop");
            await new Promise((r) => setTimeout(r, 5000));
            if (store.activeID) store.stop(store.activeID);
          }
          localModels.cancel();
          await queue.shutdown();
          unblocked();
          closing = true;
          app.quit();
        })().catch(() => {
          void dialog.showMessageBox(window, {
            type: "error",
            message:
              "Не удалось безопасно завершить запись. Проверьте свободное место и повторите.",
          });
        });
      });
      window.webContents.on("render-process-gone", () => {
        if (store.activeID) {
          const m = store.get(store.activeID);
          store.stop(m.id);
          m.status = "interrupted";
          m.error = "Окно приложения завершилось неожиданно. Аудио сохранено.";
          store.save(m);
          unblocked();
        }
      });
      app.on("second-instance", () => {
        if (window.isMinimized()) window.restore();
        window.show();
        window.focus();
      });
      window.once("ready-to-show", () => window.show());
      void window.loadFile(rendererFile);
    })
    .catch(() => {
      void dialog.showErrorBox(
        "Cool Assist Ai",
        "Не удалось открыть хранилище приложения. Проверьте свободное место и доступ к папке данных.",
      );
      app.quit();
    });
app.on("window-all-closed", () => app.quit());
