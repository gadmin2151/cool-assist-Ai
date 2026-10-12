import type {
  Action,
  Meeting,
  MeetingInfo,
  Settings,
  Snapshot,
  TaskItem,
} from "../contracts";
import { Recorder } from "./recorder";

const root = document.querySelector<HTMLDivElement>("#app")!;
const dialog = document.querySelector<HTMLDialogElement>("#dialog")!;
let snapshot: Snapshot;
let selected: Meeting | null = null;
let route: "new" | "meeting" | "tasks" | "queue" | "settings" = "new";
let tab: "summary" | "text" | "notes" | "tasks" = "summary";
let recorder: Recorder | null = null;
let compact = false;
let busy = false;
let dirtyNotes = false;
const noteDrafts = new Map<string, string>();
let settingsDraft: Settings | null = null;
let useSystemAudio = false;
let formTitle = "";
let formProject = "";
let search = "";
let microphone = "";
let deviceOptions: MediaDeviceInfo[] = [];
let refreshing = false;
let refreshAgain = false;
const html = (value: unknown) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
const duration = (seconds: number) => {
  const n = Math.max(0, Math.floor(seconds));
  return [Math.floor(n / 3600), Math.floor(n / 60) % 60, n % 60]
    .map((n) => String(n).padStart(2, "0"))
    .join(":");
};
const status = (m: MeetingInfo | Meeting) =>
  ({
    recording: m.capturePaused ? "Пауза записи" : "Идёт запись",
    captured: "В очереди",
    processing: "Обрабатывается",
    ready: "Готово",
    paused: "Обработка на паузе",
    error: "Нужно внимание",
    interrupted: "Можно восстановить",
  })[m.status];
const date = (value: string) =>
  new Date(value).toLocaleDateString("ru-RU", {
    day: "numeric",
    month: "short",
  });
function toast(message: string): void {
  const el = document.querySelector<HTMLDivElement>("#toast")!;
  el.textContent = message;
  el.classList.add("visible");
  setTimeout(() => el.classList.remove("visible"), 6000);
}
async function action(fn: () => Promise<void>): Promise<void> {
  try {
    await fn();
  } catch (error) {
    toast(
      error instanceof Error ? error.message : "Не удалось выполнить действие.",
    );
  }
}
const button = (label: string, command: string, style = "quiet") =>
  `<button class="${style}" data-command="${command}">${label}</button>`;
function sidebar(): string {
  const jobs = snapshot.meetings.filter(
    (m) => !["ready", "recording"].includes(m.status),
  );
  const tasks = snapshot.meetings.reduce(
    (n, m) => n + m.tasks.filter((t) => !t.done).length,
    0,
  );
  return `<aside class="sidebar"><div class="brand"><img src="logo.svg" alt="">Cool Assist Ai</div>${button("+ Новая встреча", "new", "primary")}
    <nav class="nav" aria-label="Навигация"><button data-command="library" class="${route === "meeting" ? "active" : ""}">▦ &nbsp; Встречи <span class="count">${snapshot.meetings.length}</span></button><button data-command="tasks" class="${route === "tasks" ? "active" : ""}">☑ &nbsp; Все задачи <span class="count">${tasks}</span></button><button data-command="queue" class="${route === "queue" ? "active" : ""}">◷ &nbsp; Обработка <span class="count">${jobs.length}</span></button></nav>
    <div class="eyebrow">Недавние встречи</div><input id="search" class="search" aria-label="Поиск встреч" placeholder="Поиск встреч" value="${html(search)}"><div class="meetings">${snapshot.meetings.length ? snapshot.meetings.map((m) => `<button class="meeting-row ${selected?.id === m.id && route === "meeting" ? "selected" : ""}" data-meeting="${m.id}" ${!matches(m) ? "hidden" : ""}><strong>${html(m.title)}</strong><small>${date(m.startedAt)} · ${duration(m.duration)} · ${status(m)}</small></button>`).join("") : '<p class="hint">Здесь будут ваши встречи и протоколы.</p>'}</div><div class="sidebar-footer">${button("⚙ &nbsp; Настройки", "settings")}<span class="small muted">Cool Assist Ai · ${html(snapshot.version)}</span></div></aside>`;
}
function matches(m: MeetingInfo): boolean {
  return `${m.title} ${m.project}`
    .toLocaleLowerCase()
    .includes(search.toLocaleLowerCase());
}
function newView(): string {
  return `<div class="new-form screen-enter"><div class="new-hero"><div class="eyebrow">От разговора к действию</div><h1>Слушайте собеседника.<br>Главное останется.</h1><p class="muted">Запись, полная расшифровка и понятный план действий.</p></div><form id="record-form" class="panel"><h2>Новая встреча</h2><label class="field"><span>Название</span><input name="title" placeholder="О чём будете говорить?" maxlength="200" value="${html(formTitle)}"></label><div class="form-grid"><label class="field"><span>Проект · необязательно</span><input name="project" placeholder="Например, запуск продукта" maxlength="200" value="${html(formProject)}"></label><label class="field"><span>Микрофон</span><select name="microphone"><option value="">Системный по умолчанию</option>${deviceOptions.map((d) => `<option value="${html(d.deviceId)}" ${d.deviceId === microphone ? "selected" : ""}>${html(d.label || "Микрофон")}</option>`).join("")}</select></label></div>${snapshot.platform === "win32" ? `<label class="check"><input type="checkbox" name="system" ${useSystemAudio ? "checked" : ""}><span>Также записывать звук Windows<br><small class="muted">Звук всех приложений. Видео экрана не сохраняется.</small></span></label>` : '<p class="hint">Записывается выбранный аудиовход. На Linux системный звук можно подать через монитор PipeWire/PulseAudio.</p>'}${snapshot.settings.provider === "local" ? `<p class="hint">На этом компьютере · Whisper + Qwen<br>${snapshot.localModels.ready ? "Модели готовы. Интернет и API-ключ не нужны." : "Для распознавания скачайте модели в настройках. Записывать можно уже сейчас."}</p>` : !snapshot.hasKey || !snapshot.settings.cloudConsent ? '<div class="notice">Можно записывать без интернета. Для расшифровки добавьте API-ключ и включите OpenAI в настройках.</div>' : `<p class="hint">Распознавание по ходу записи · ${html(snapshot.settings.transcriptionModel)}<br>Резюме · ${html(snapshot.settings.summaryModel)}</p>`}<div class="actions"><button type="submit" class="primary" ${busy || snapshot.activeID ? "disabled" : ""}>${busy ? "Подключаю микрофон…" : "● Начать запись"}</button><button type="button" data-command="devices">Обновить устройства</button></div><p class="hint">Предупредите участников о записи. Для онлайн-встреч используйте наушники.</p></form></div>`;
}
function taskRows(m: Meeting, limit = 1000): string {
  return m.tasks
    .slice(0, limit)
    .map(
      (t) =>
        `<label class="task ${t.done ? "done" : ""}"><input type="checkbox" data-task="${t.id}" data-owner-meeting="${m.id}" ${t.done ? "checked" : ""}><span><span class="task-text">${html(t.text)}</span><span class="task-meta">${html(t.owner || "Без исполнителя")} · ${html(t.due || "Без срока")}</span></span></label>`,
    )
    .join("");
}
function evidence(
  m: Meeting,
  items: { source: string; quote: string }[],
): string {
  return items
    .map((e) => {
      const c = m.chunks.find((c) => c.id === e.source);
      return c
        ? `<button class="evidence" data-source="${c.id}" title="${html(e.quote)}">↗ ${duration(c.start)}</button>`
        : "";
    })
    .join("");
}
function summary(m: Meeting): string {
  if (!m.brief)
    return `<div class="panel empty"><img class="empty-logo" src="logo.svg" alt=""><strong>${m.status === "recording" ? "Разговор сохраняется" : "Резюме ещё не готово"}</strong><p>Полная речь доступна во вкладке «Расшифровка».<br>${m.status === "recording" ? "Резюме появится после завершения встречи." : "Запустите обработку, когда будете готовы."}</p>${m.status !== "recording" ? button("Составить резюме", "resume", "primary") : ""}</div>`;
  const points = (
    title: string,
    rows: { text: string; evidence: { source: string; quote: string }[] }[],
  ) =>
    rows.length
      ? `<section class="section"><h3>${title}</h3>${rows.map((p) => `<div class="point"><div><p>${html(p.text)}</p>${evidence(m, p.evidence)}</div></div>`).join("")}</section>`
      : "";
  return `<div class="panel"><div class="eyebrow">Главное</div><p class="intro">${html(m.brief.overview)}</p>${m.brief.topics.map((t) => points(html(t.title), [t])).join("")}${points("Решения", m.brief.decisions)}${points("Открытые вопросы", m.brief.questions)}${m.brief.actions.length ? `<section class="section"><h3>Ближайшие действия</h3>${m.brief.actions.map((a, i) => `<div class="point"><div><p>${html(a.text)}</p><div class="task-meta">${html(a.owner || "Исполнитель не указан")} · ${html(a.due || "Срок не указан")}</div>${evidence(m, a.evidence)}<button class="evidence" data-proposal="${i}">+ В задачи</button></div></div>`).join("")}</section>` : ""}<p class="summary-warning">Резюме: ${html(m.summaryModelUsed || m.settings.summaryModel)}. Проверьте имена, числа и решения по исходной речи. Задачи добавляются после вашего подтверждения.</p>${button("Обновить резюме", "summarize")}</div>`;
}
function meetingView(m: Meeting): string {
  const active = m.id === snapshot.activeID;
  const pending = m.chunks.filter((c) => c.text === undefined).length;
  const header = `<header class="top"><div><div class="eyebrow">${html(m.project || "Встреча")}</div><h1>${html(m.title)}</h1><span class="muted">${date(m.startedAt)} · ${duration(m.duration)} · ${status(m)}</span></div><div class="actions">${button("Экспорт .md", "export")}${button("Название", "rename")}${button("Удалить", "remove", "quiet danger")}</div></header>`;
  const statusbar =
    m.status !== "ready"
      ? `<div class="status-strip"><div><strong>${active ? (m.capturePaused ? "Ⅱ Пауза записи" : "● Идёт запись") : status(m)}</strong><div class="small muted">${m.chunks.length - pending} из ${m.chunks.length} фрагментов распознано${pending ? " · аудио сохранено" : ""}</div></div><div class="actions">${!active && m.status === "processing" ? button("Пауза", "pause-job") : pending || !m.brief ? button("Продолжить", "resume") : ""}</div></div>`
      : "";
  let content = "";
  if (tab === "summary") content = summary(m);
  if (tab === "text")
    content = `<div class="panel live-transcript"><h2>${active ? "Живая расшифровка" : "Полная расшифровка"}</h2>${
      m.chunks.some((c) => c.text?.trim())
        ? m.chunks
            .filter((c) => c.text?.trim())
            .map(
              (c) =>
                `<div class="utterance" id="source-${c.id}"><div class="time">${duration(c.start)}</div><p>${html(c.text)}</p></div>`,
            )
            .join("")
        : `<div class="empty"><strong>${active ? "Слушаю…" : "Распознанной речи пока нет"}</strong><p>${active ? "Речь появится после первого фрагмента." : "Проверьте настройки AI и продолжите обработку."}<br>При отсутствии сети аудио остаётся на диске.</p></div>`
    }</div>`;
  if (tab === "notes")
    content = `<div class="panel"><h2>Личные заметки</h2><p class="hint">Эти заметки не отправляются в OpenAI.</p><textarea id="notes" aria-label="Личные заметки" placeholder="Ваши мысли и важные детали…">${html(noteDrafts.get(m.id) ?? m.notes)}</textarea><div class="notes-save">${button("Сохранить заметки", "save-notes", "primary")}</div>${m.bookmarks.length ? `<div class="section"><h3>Отмеченные моменты</h3>${m.bookmarks.map((s) => `<span class="pill">${duration(s)}</span>`).join(" ")}</div>` : ""}</div>`;
  if (tab === "tasks")
    content = `<div class="panel"><h2>План действий</h2>${taskRows(m) || '<p class="muted">Пока нет задач. Добавьте свою или выберите действие из резюме.</p>'}${button("+ Добавить задачу", "add-task", "full task-add")}</div>`;
  return `${header}${m.error ? `<div class="notice">${html(m.error)}</div>` : ""}${statusbar}<nav class="tabs" aria-label="Раздел встречи">${(
    [
      ["summary", "Резюме"],
      ["text", "Расшифровка"],
      ["notes", "Заметки"],
      ["tasks", "Задачи"],
    ] as const
  )
    .map(
      ([id, label]) =>
        `<button data-tab="${id}" class="${tab === id ? "active" : ""}">${label}</button>`,
    )
    .join(
      "",
    )}</nav><div class="columns"><div>${content}</div><aside class="panel task-side"><h2>План действий <span class="pill">${m.tasks.length}</span></h2>${taskRows(m, 12) || '<p class="hint">Из резюме можно добавить поручения с исполнителем и сроком.</p>'}${button("+ Добавить задачу", "add-task", "full task-add")}</aside></div>`;
}
function settingsView(): string {
  const s = settingsDraft ?? snapshot.settings;
  const local = snapshot.localModels;
  const megabytes = (bytes: number) => (bytes / 1024 / 1024).toFixed(0);
  return `<div class="settings screen-enter"><div class="eyebrow">Ваше рабочее пространство</div><h1>Настройки</h1><form id="settings-form"><div class="panel"><h2>Распознавание и резюме</h2><label class="field"><span>Где обрабатывать встречу</span><select name="provider"><option value="local" ${s.provider === "local" ? "selected" : ""}>На этом компьютере · без API-ключа</option><option value="openai" ${s.provider !== "local" ? "selected" : ""}>OpenAI · через интернет</option></select></label><p class="hint">Локально: Whisper распознаёт речь, Qwen составляет резюме. Облачный режим: Аудиофрагменты отправляются для распознавания, текст — для резюме. Личные заметки и видео не отправляются. Интернет и оплата API нужны только для облачной обработки. Настройки моделей ниже относятся к OpenAI.</p><label class="check"><input type="checkbox" name="consent" ${s.cloudConsent ? "checked" : ""}><span>Разрешить отправку аудио и расшифровки в OpenAI</span></label><div class="form-grid"><label class="field"><span>Модель распознавания</span><input name="transcription" list="models" value="${html(s.transcriptionModel)}" required></label><label class="field"><span>Модель резюме</span><input name="summary" list="models" value="${html(s.summaryModel)}" required></label></div><datalist id="models"></datalist><label class="field"><span>Язык</span><select name="language">${[
    ["auto", "Определять автоматически"],
    ["ru", "Русский"],
    ["ro", "Română"],
    ["en", "English"],
    ["uk", "Українська"],
    ["de", "Deutsch"],
    ["fr", "Français"],
    ["es", "Español"],
  ]
    .map(
      ([id, label]) =>
        `<option value="${id}" ${s.language === id ? "selected" : ""}>${label}</option>`,
    )
    .join(
      "",
    )}</select></label><label class="field"><span>Имена, компании и термины</span><textarea name="glossary" maxlength="1200" placeholder="Например: название продукта, имена участников, профессиональные термины">${html(s.glossary)}</textarea></label><p class="hint">Словарь помогает распознавать редкие слова. Это подсказка, а не гарантия точности.</p><button class="primary" type="submit">Сохранить настройки</button></div></form><div class="panel"><h2>Локальные модели</h2><p class="hint">Whisper Small, Silero VAD и Qwen3 4B Q4 · около 2,5 ГБ. Скачать один раз с Hugging Face, далее работают без сети. Рекомендуется 16 ГБ RAM. Скорость зависит от процессора; Windows/Linux используют CPU.</p><p id="local-status">${local.checking ? "Проверяю модели…" : local.ready ? "✓ Модели проверены и готовы" : local.downloading ? html(local.active) : "Модели ещё не установлены"}</p><progress id="local-progress" max="${local.total}" value="${local.completed + local.downloaded}"></progress><p class="hint" id="local-size">${megabytes(local.completed + local.downloaded)} / ${megabytes(local.total)} МБ</p>${local.error ? `<p class="hint">${html(local.error)}</p>` : ""}<div class="actions"><button type="button" data-command="download-models" ${local.ready || local.checking || local.downloading ? "disabled" : ""}>${local.downloading ? "Загрузка…" : "Скачать модели"}</button>${local.downloading ? button("Остановить загрузку", "cancel-models") : ""}</div><p class="hint">Прерванную загрузку можно продолжить. Контрольные суммы проверяются до использования. Самопроизвольного переключения в облако нет.</p></div><div class="panel"><h2>OpenAI API-ключ</h2><p class="hint">${snapshot.hasKey ? `Ключ ${snapshot.persistentKey ? "сохранён в защищённом хранилище ОС" : "доступен до закрытия приложения"}.` : "Ключ не настроен."} Ключ не включается в экспорт и не передаётся окну приложения.</p><form id="key-form"><label class="field"><span>Новый ключ</span><input name="key" type="password" autocomplete="off" placeholder="Вставьте ваш API-ключ" maxlength="512" required></label><label class="check"><input name="persist" type="checkbox" ${snapshot.secureStorage ? "checked" : ""}><span>Сохранять в защищённом хранилище ОС</span></label>${!snapshot.secureStorage ? '<p class="hint">Хранилище ОС недоступно. Можно использовать ключ только до закрытия приложения; для постоянного хранения настройте Secret Service.</p>' : ""}<div class="actions"><button class="primary" type="submit">Сохранить ключ</button><button type="button" data-command="models" ${snapshot.hasKey ? "" : "disabled"}>Проверить и загрузить модели</button><button type="button" data-command="remove-key" class="quiet danger" ${snapshot.hasKey ? "" : "disabled"}>Удалить ключ</button></div></form><p class="hint">API оплачивается отдельно от подписки ChatGPT. Доступ к моделям зависит от вашего аккаунта. Автоматического выбора более дорогой модели нет.</p></div><div class="panel"><h2>Хранение и приватность</h2><p class="hint">Аудио сохраняется на этом компьютере до удаления встречи. Удаление переносит материалы в Корзину. Незавершённые фрагменты восстанавливаются после сбоя. Полная расшифровка доступна в экспорте Markdown.</p></div></div>`;
}
function queueView(): string {
  const jobs = snapshot.meetings.filter(
    (m) => !["ready", "recording"].includes(m.status),
  );
  return `<div class="screen-enter"><div class="eyebrow">Фоновая работа</div><h1>Обработка</h1><p class="muted">Пока AI обрабатывает встречу, можно открыть другую или начать запись.</p><div class="panel">${jobs.length ? jobs.map((m) => `<div class="job"><div><h3>${html(m.title)}</h3><span class="muted">${status(m)} · ${m.completedChunks}/${m.chunkCount} фрагментов</span>${m.error ? `<p class="hint">${html(m.error)}</p>` : ""}<progress max="${Math.max(1, m.chunkCount)}" value="${m.completedChunks}"></progress></div><div class="actions"><button data-meeting="${m.id}">Открыть</button><button data-job="${m.id}" data-job-action="${m.status === "processing" ? "pause" : "resume"}">${m.status === "processing" ? "Пауза" : "Продолжить"}</button></div></div>`).join("") : '<div class="empty"><strong>Всё обработано</strong><p>Здесь будут видны текущие и приостановленные задания.</p></div>'}</div></div>`;
}
function allTasks(): string {
  const meetings = snapshot.meetings.filter((m) => m.tasks.length);
  return `<div class="screen-enter"><div class="eyebrow">От слов к действиям</div><h1>Все задачи</h1>${meetings.length ? meetings.map((m) => `<div class="panel"><button class="quiet" data-meeting="${m.id}">${html(m.title)} ↗</button>${m.tasks.map((t) => `<label class="task ${t.done ? "done" : ""}"><input type="checkbox" data-task="${t.id}" data-owner-meeting="${m.id}" ${t.done ? "checked" : ""}><span><span class="task-text">${html(t.text)}</span><span class="task-meta">${html(t.owner || "Без исполнителя")} · ${html(t.due || "Без срока")}</span></span></label>`).join("")}</div>`).join("") : '<div class="panel empty"><strong>Ни одного потерянного поручения</strong><p>Добавляйте задачи из резюме или создавайте их внутри встречи.</p></div>'}</div>`;
}
function dock(): string {
  if (!recorder) return "";
  return `<div class="record-dock ${recorder.paused ? "paused" : ""}"><span class="record-dot"></span><span class="time" id="record-time">${duration(recorder.samples / 16000)}</span><canvas class="wave" id="wave" width="300" height="76" aria-label="Уровень звука"></canvas><span class="small muted label">${recorder.paused ? "Пауза" : "Слушаю"}</span><button class="icon quiet" data-command="mark" aria-label="Отметить важный момент">⚑</button><button class="icon" data-command="pause-record" aria-label="${recorder.paused ? "Продолжить запись" : "Приостановить запись"}">${recorder.paused ? "▶" : "Ⅱ"}</button><button class="icon primary" data-command="stop" aria-label="Завершить запись">■</button><button class="icon quiet" data-command="compact" aria-label="${compact ? "Открыть рабочее пространство" : "Компактный режим"}">${compact ? "↗" : "↙"}</button></div>`;
}
function render(force = false): void {
  if (!snapshot) return;
  if (
    !force &&
    (dialog.open ||
      document.activeElement?.matches("input,textarea,select") ||
      document.querySelector<HTMLInputElement>("#key-form input[name=key]")
        ?.value)
  )
    return;
  root.innerHTML = `<div class="shell">${sidebar()}<main class="main">${route === "new" ? newView() : route === "settings" ? settingsView() : route === "queue" ? queueView() : route === "tasks" ? allTasks() : selected ? meetingView(selected) : newView()}</main></div>${dock()}`;
  document.body.classList.toggle("compact", compact);
}
async function refresh(force = false): Promise<void> {
  if (refreshing) {
    refreshAgain = true;
    return;
  }
  refreshing = true;
  try {
    snapshot = await window.cool.snapshot();
    const localStatus = document.querySelector("#local-status");
    const progress =
      document.querySelector<HTMLProgressElement>("#local-progress");
    const size = document.querySelector("#local-size");
    if (localStatus && progress && size) {
      const m = snapshot.localModels;
      localStatus.textContent = m.checking
        ? "Проверяю модели…"
        : m.ready
          ? "✓ Модели проверены и готовы"
          : m.active || m.error || "Модели ещё не установлены";
      progress.value = m.completed + m.downloaded;
      size.textContent = `${((m.completed + m.downloaded) / 1024 / 1024).toFixed(0)} / ${(m.total / 1024 / 1024).toFixed(0)} МБ`;
    }
    if (selected) {
      if (snapshot.meetings.some((m) => m.id === selected!.id))
        selected = await window.cool.meeting(selected.id);
      else {
        selected = null;
        route = "new";
      }
    }
    render(force);
  } finally {
    refreshing = false;
    if (refreshAgain) {
      refreshAgain = false;
      void refresh();
    }
  }
}
function canLeaveNotes(): boolean {
  if (!dirtyNotes) return true;
  if (
    window.confirm(
      "В заметках есть несохранённые изменения. Перейти без сохранения?",
    )
  ) {
    if (selected) noteDrafts.delete(selected.id);
    dirtyNotes = false;
    return true;
  }
  return false;
}
async function selectMeeting(meetingID: string): Promise<void> {
  if (!canLeaveNotes()) return;
  selected = await window.cool.meeting(meetingID);
  route = "meeting";
  tab = "summary";
  render(true);
}
async function stopRecording(): Promise<void> {
  if (!recorder || busy) return;
  busy = true;
  const active = recorder;
  try {
    await active.stop();
  } finally {
    recorder = null;
    busy = false;
    if (compact) {
      compact = false;
      await window.cool.compact(false);
    }
    await refresh(true);
  }
}
async function startRecording(form: HTMLFormElement): Promise<void> {
  if (busy || recorder) return;
  const data = new FormData(form);
  formTitle = String(data.get("title") ?? "");
  formProject = String(data.get("project") ?? "");
  microphone = String(data.get("microphone") ?? "");
  const systemAudio = data.has("system");
  busy = true;
  render(true);
  let mic: MediaStream | null = null;
  let system: MediaStream | null = null;
  let meeting: Meeting | null = null;
  try {
    meeting = await window.cool.start({
      title: formTitle,
      project: formProject,
      systemAudio,
    });
    if (systemAudio) {
      system = await navigator.mediaDevices.getDisplayMedia({
        video: true,
        audio: true,
      });
      if (!system.getAudioTracks().length)
        throw new Error(
          "Системный звук недоступен. Повторите запись только с микрофоном.",
        );
    }
    mic = await navigator.mediaDevices.getUserMedia({
      audio: {
        ...(microphone ? { deviceId: { exact: microphone } } : {}),
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
      video: false,
    });
    recorder = new Recorder(meeting.id, (message) => {
      toast(message);
      void action(stopRecording);
    });
    await recorder.connect(mic, system);
    animate();
    selected = meeting;
    route = "meeting";
    tab = "text";
    formTitle = "";
    formProject = "";
  } catch (error) {
    mic?.getTracks().forEach((t) => t.stop());
    system?.getTracks().forEach((t) => t.stop());
    if (recorder?.context && recorder.context.state !== "closed")
      await recorder.context.close();
    recorder = null;
    if (meeting) await window.cool.stop(meeting.id);
    throw error;
  } finally {
    busy = false;
    await refresh(true);
  }
}
function taskDialog(proposal?: Action): void {
  if (!selected) return;
  const meetingID = selected.id;
  dialog.innerHTML = `<form id="task-form"><h2>${proposal ? "Добавить поручение" : "Новая задача"}</h2><label class="field"><span>Что нужно сделать</span><input name="text" value="${html(proposal?.text || "")}" maxlength="2000" required></label><label class="field"><span>Исполнитель</span><input name="owner" value="${html(proposal?.owner || "")}" maxlength="120" placeholder="Не указан"></label><label class="field"><span>Срок</span><input name="due" value="${html(proposal?.due || "")}" maxlength="120" placeholder="Не указан"></label><p class="hint">Проверьте формулировку, исполнителя и срок. Поручение будет добавлено только после нажатия кнопки.</p><div class="actions"><button type="button" data-command="close-dialog">Отмена</button><button type="submit" class="primary">Добавить задачу</button></div></form>`;
  dialog.showModal();
  dialog.querySelector("form")!.addEventListener("submit", (event) => {
    event.preventDefault();
    void action(async () => {
      const data = new FormData(event.target as HTMLFormElement);
      const m = await window.cool.meeting(meetingID);
      const task: TaskItem = {
        id: crypto.randomUUID(),
        text: String(data.get("text")).trim(),
        owner: String(data.get("owner")).trim(),
        due: String(data.get("due")).trim(),
        done: false,
        ...(proposal?.evidence[0]
          ? { source: proposal.evidence[0].source }
          : {}),
      };
      if (!task.text) throw new Error("Введите текст задачи.");
      if (
        m.tasks.some((t) => t.text === task.text && t.source === task.source)
      ) {
        toast("Эта задача уже добавлена.");
        dialog.close();
        return;
      }
      await window.cool.saveMeeting(meetingID, { tasks: [...m.tasks, task] });
      dialog.close();
      await refresh(true);
    });
  });
}
async function command(name: string): Promise<void> {
  if (["new", "library", "tasks", "queue", "settings"].includes(name)) {
    if (!canLeaveNotes()) return;
    if (name === "library") {
      if (snapshot.meetings[0]) await selectMeeting(snapshot.meetings[0].id);
      else route = "new";
    } else route = name as typeof route;
    render(true);
    return;
  }
  if (name === "close-dialog") {
    dialog.close();
    return;
  }
  if (name === "devices") {
    deviceOptions = (await navigator.mediaDevices.enumerateDevices()).filter(
      (d) => d.kind === "audioinput",
    );
    render(true);
    return;
  }
  if (name === "stop") {
    await stopRecording();
    return;
  }
  if (name === "pause-record") {
    if (recorder) {
      await recorder.pause();
      render(true);
    }
    return;
  }
  if (name === "mark") {
    if (recorder) {
      await window.cool.mark(recorder.id);
      toast("Момент отмечен.");
    }
    return;
  }
  if (name === "compact") {
    compact = !compact;
    await window.cool.compact(compact);
    render(true);
    return;
  }
  if (name === "download-models") {
    await window.cool.downloadModels();
    await refresh(true);
    return;
  }
  if (name === "cancel-models") {
    await window.cool.cancelModels();
    await refresh(true);
    return;
  }
  if (name === "models") {
    toast("Проверяю ключ и загружаю модели…");
    const models = await window.cool.models();
    document.querySelector("#models")!.innerHTML = models
      .map((m) => `<option value="${html(m)}"></option>`)
      .join("");
    toast(`Ключ работает. Доступно моделей: ${models.length}`);
    return;
  }
  if (name === "remove-key") {
    await window.cool.removeKey();
    await refresh(true);
    return;
  }
  if (!selected) return;
  if (name === "export") {
    if (await window.cool.exportMarkdown(selected.id))
      toast("Markdown сохранён.");
  }
  if (name === "remove") {
    await window.cool.remove(selected.id);
    await refresh(true);
  }
  if (name === "resume" || name === "summarize") {
    await window.cool.queue(selected.id, name);
    await refresh(true);
  }
  if (name === "pause-job") {
    await window.cool.queue(selected.id, "pause");
    await refresh(true);
  }
  if (name === "add-task") taskDialog();
  if (name === "save-notes") {
    await window.cool.saveMeeting(selected.id, {
      notes: document.querySelector<HTMLTextAreaElement>("#notes")!.value,
    });
    noteDrafts.delete(selected.id);
    dirtyNotes = false;
    toast("Заметки сохранены.");
  }
  if (name === "rename") {
    const meetingID = selected.id;
    dialog.innerHTML = `<form id="rename-form"><h2>Название встречи</h2><label class="field"><span>Название</span><input name="title" maxlength="200" value="${html(selected.title)}" required></label><label class="field"><span>Проект</span><input name="project" maxlength="200" value="${html(selected.project)}"></label><div class="actions"><button type="button" data-command="close-dialog">Отмена</button><button class="primary">Сохранить</button></div></form>`;
    dialog.showModal();
    dialog.querySelector("form")!.addEventListener("submit", (event) => {
      event.preventDefault();
      const data = new FormData(event.target as HTMLFormElement);
      void action(async () => {
        await window.cool.saveMeeting(meetingID, {
          title: String(data.get("title")),
          project: String(data.get("project")),
        });
        dialog.close();
        await refresh(true);
      });
    });
  }
}
document.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("button");
  if (
    !target ||
    (target.closest("form") && target.getAttribute("type") === "submit")
  )
    return;
  void action(async () => {
    if (target.dataset.command) await command(target.dataset.command);
    if (target.dataset.meeting) await selectMeeting(target.dataset.meeting);
    if (target.dataset.tab && canLeaveNotes()) {
      tab = target.dataset.tab as typeof tab;
      render(true);
    }
    if (target.dataset.source && canLeaveNotes()) {
      tab = "text";
      render(true);
      document
        .getElementById(`source-${target.dataset.source}`)
        ?.scrollIntoView({
          behavior: matchMedia("(prefers-reduced-motion: reduce)").matches
            ? "instant"
            : "smooth",
          block: "center",
        });
    }
    if (target.dataset.proposal)
      taskDialog(selected?.brief?.actions[Number(target.dataset.proposal)]);
    if (target.dataset.job) {
      await window.cool.queue(
        target.dataset.job,
        target.dataset.jobAction as "pause" | "resume",
      );
      await refresh(true);
    }
  });
});
document.addEventListener("input", (event) => {
  const el = event.target as HTMLInputElement;
  if (el.id === "search") {
    search = el.value;
    document
      .querySelectorAll<HTMLButtonElement>(".meeting-row")
      .forEach((row) => {
        const m = snapshot.meetings.find((m) => m.id === row.dataset.meeting);
        row.hidden = !m || !matches(m);
      });
  }
  if (el.id === "notes" && selected) {
    dirtyNotes = true;
    noteDrafts.set(selected.id, el.value);
  }
  if (el.closest("#record-form")) {
    const form = el.closest("form")!;
    const data = new FormData(form);
    formTitle = String(data.get("title") ?? "");
    formProject = String(data.get("project") ?? "");
    microphone = String(data.get("microphone") ?? "");
    useSystemAudio = data.has("system");
  }
  if (el.closest("#settings-form")) {
    const data = new FormData(el.closest("form")!);
    settingsDraft = {
      provider: String(data.get("provider")) as "local" | "openai",
      transcriptionModel: String(data.get("transcription")),
      summaryModel: String(data.get("summary")),
      language: String(data.get("language")),
      glossary: String(data.get("glossary")),
      cloudConsent: data.has("consent"),
    };
  }
});
document.addEventListener("change", (event) => {
  const el = event.target as HTMLInputElement;
  if (el.dataset.task && el.dataset.ownerMeeting)
    void action(async () => {
      await window.cool.setTaskDone(
        el.dataset.ownerMeeting!,
        el.dataset.task!,
        el.checked,
      );
      await refresh(true);
    });
});
document.addEventListener("submit", (event) => {
  const form = event.target as HTMLFormElement;
  if (!["record-form", "settings-form", "key-form"].includes(form.id)) return;
  event.preventDefault();
  void action(async () => {
    if (form.id === "record-form") {
      await startRecording(form);
      return;
    }
    const data = new FormData(form);
    if (form.id === "settings-form") {
      const s: Settings = {
        provider: String(data.get("provider")) as "local" | "openai",
        transcriptionModel: String(data.get("transcription")),
        summaryModel: String(data.get("summary")),
        language: String(data.get("language")),
        glossary: String(data.get("glossary")),
        cloudConsent: data.has("consent"),
      };
      await window.cool.saveSettings(s);
      settingsDraft = null;
      toast("Настройки сохранены.");
    }
    if (form.id === "key-form") {
      const key = String(data.get("key") ?? "");
      await window.cool.saveKey(key, data.has("persist"));
      form.reset();
      toast("Ключ сохранён. Можно проверить доступ к моделям.");
    }
    await refresh(true);
  });
});
window.cool.onUpdate(() => {
  void action(() => refresh());
});
window.cool.onCommand((name) => {
  void action(() =>
    name === "stop" ? stopRecording() : command("pause-record"),
  );
});
let frame = 0;
function animate(): void {
  cancelAnimationFrame(frame);
  if (!recorder) return;
  frame = requestAnimationFrame(animate);
  const time = document.querySelector("#record-time");
  if (time) time.textContent = duration(recorder.samples / 16000);
  const canvas = document.querySelector<HTMLCanvasElement>("#wave");
  const context = canvas?.getContext("2d");
  if (!canvas || !context) return;
  context.clearRect(0, 0, canvas.width, canvas.height);
  context.fillStyle = recorder.paused ? "#777780" : "#d60000";
  const values = new Uint8Array(recorder.analyser?.frequencyBinCount ?? 128);
  if (!recorder.paused) recorder.analyser?.getByteFrequencyData(values);
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  for (let i = 0; i < 25; i++) {
    const sample = values[Math.floor((i * values.length) / 25)] ?? 0;
    const height =
      recorder.paused || reduce ? 5 : Math.max(4, (sample / 255) * 64);
    context.beginPath();
    context.roundRect(i * 12 + 2, (76 - height) / 2, 6, height, 3);
    context.fill();
  }
}
void action(async () => {
  await refresh(true);
});
window.addEventListener("beforeunload", () => cancelAnimationFrame(frame));
