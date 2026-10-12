import { validateBrief } from "./openai";
import type { Settings, TaskItem } from "../contracts";
export function id(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      value,
    )
  )
    throw new Error("Некорректная встреча.");
  return value;
}
export function text(value: unknown, max: number): string {
  if (typeof value !== "string" || value.length > max || value.includes("\0"))
    throw new Error("Проверьте длину и формат текста.");
  return value;
}
export function model(value: unknown): string {
  const v = text(value, 120).trim();
  if (!/^[a-zA-Z0-9][a-zA-Z0-9:._/-]*$/.test(v))
    throw new Error("Укажите ID модели.");
  return v;
}
export function settings(value: Settings): Settings {
  if (
    !value ||
    (value.provider !== undefined &&
      !["local", "openai"].includes(value.provider)) ||
    typeof value.cloudConsent !== "boolean"
  )
    throw new Error("Некорректные настройки.");
  if (
    !["auto", "ru", "ro", "en", "uk", "de", "fr", "es"].includes(value.language)
  )
    throw new Error("Некорректный язык.");
  return {
    provider: value.provider ?? "openai",
    transcriptionModel: model(value.transcriptionModel),
    summaryModel: model(value.summaryModel),
    language: value.language,
    glossary: text(value.glossary, 1200),
    cloudConsent: value.cloudConsent,
  };
}
export function tasks(value: TaskItem[]): TaskItem[] {
  if (!Array.isArray(value) || value.length > 1000)
    throw new Error("Слишком много задач.");
  const seen = new Set<string>();
  return value.map((t) => {
    if (!t || typeof t !== "object") throw new Error("Некорректная задача.");
    const key = id(t.id);
    if (seen.has(key) || typeof t.done !== "boolean")
      throw new Error("Некорректная задача.");
    seen.add(key);
    return {
      id: key,
      text: text(t.text, 2000),
      owner: text(t.owner, 120),
      due: text(t.due, 120),
      done: t.done,
      ...(t.source ? { source: text(t.source, 80) } : {}),
    };
  });
}

/** Validate untrusted disk snapshots before library/queue code can observe them. */
export function storedMeeting(value: unknown): import("../contracts").Meeting {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("Некорректная встреча.");
  const m = value as import("../contracts").Meeting;
  id(m.id);
  text(m.title, 200);
  text(m.project, 200);
  text(m.notes, 200000);
  if (
    m.schema !== 1 ||
    typeof m.startedAt !== "string" ||
    !Number.isFinite(Date.parse(m.startedAt)) ||
    !Number.isFinite(m.duration) ||
    m.duration < 0 ||
    ![
      "recording",
      "captured",
      "processing",
      "ready",
      "paused",
      "error",
      "interrupted",
    ].includes(m.status) ||
    !["microphone", "microphone+system"].includes(m.source) ||
    (m.capturePaused !== undefined && typeof m.capturePaused !== "boolean")
  )
    throw new Error("Некорректные сведения о записи.");
  settings(m.settings);
  tasks(m.tasks);
  if (
    !Array.isArray(m.bookmarks) ||
    m.bookmarks.length > 20000 ||
    m.bookmarks.some((time) => !Number.isFinite(time) || time < 0)
  )
    throw new Error("Некорректные отметки.");
  if (!Array.isArray(m.chunks) || m.chunks.length > 20000)
    throw new Error("Некорректные аудиофрагменты.");
  let end = 0;
  const ids = new Set<string>();
  for (const chunk of m.chunks) {
    if (!chunk || typeof chunk !== "object")
      throw new Error("Некорректный аудиофрагмент.");
    const key = id(chunk.id);
    if (
      ids.has(key) ||
      !Number.isFinite(chunk.start) ||
      Math.abs(chunk.start - end) > 1 / 16000 ||
      !Number.isFinite(chunk.duration) ||
      chunk.duration <= 0 ||
      chunk.duration > 120 ||
      !Number.isSafeInteger(chunk.samples) ||
      chunk.samples <= 0 ||
      Math.abs(chunk.samples / 16000 - chunk.duration) > 1 / 16000 ||
      typeof chunk.voiced !== "boolean"
    )
      throw new Error("Некорректная шкала времени аудио.");
    if (chunk.text !== undefined) text(chunk.text, 30000);
    ids.add(key);
    end = chunk.start + chunk.duration;
  }
  if (Math.abs(m.duration - end) > 1 / 16000)
    throw new Error("Продолжительность не совпадает с аудио.");
  if (m.error !== undefined) text(m.error, 8000);
  if (m.summaryModelUsed !== undefined) model(m.summaryModelUsed);
  if (m.brief !== undefined) {
    // Results produced by the app are checked again after restart; raw speech stays on disk.
    validateBrief(m.brief, m.chunks);
  }
  return m;
}
