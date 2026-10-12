import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import type { Brief, Meeting, Settings } from "../contracts";
import { MeetingStore, atomicJSON } from "./store";
import {
  APIError,
  OpenAIClient,
  sourceBatches,
  validateBrief,
  validateInputEvidence,
} from "./openai";

const local = (settings: Settings) => settings.provider === "local";
const LOCAL_SUMMARY_MODEL = "Qwen3-4B-Q4_K_M";
const MERGE_INSTRUCTION =
  "Объедини исходные пункты протокола по темам. Сохрани отрицания, неопределённость, source и дословные quote. Убери только повторы, не добавляй факты. Записи с одним ключом — части одного пункта.\n";
function pieces(value: string, maximum: number): string[] {
  const result = Array.from(value).reduce<string[]>((parts, char) => {
    if (
      !parts.length ||
      parts[parts.length - 1]!.length + char.length > maximum
    )
      parts.push(char);
    else parts[parts.length - 1] += char;
    return parts;
  }, []);
  if (result.length > 1 && result[result.length - 1]!.trim().length < 3)
    result[result.length - 2] += result.pop()!;
  return result;
}

/** Every reduction level is bounded; an unusually verbose model cannot overflow the next context. */
export function reductionBatches(briefs: Brief[], budget: number): string[] {
  const rows: string[] = [];
  for (const [index, brief] of briefs.entries())
    for (const kind of [
      "topics",
      "decisions",
      "actions",
      "questions",
    ] as const) {
      for (const [pointIndex, point] of brief[kind].entries()) {
        // Split rather than truncate long derived text/evidence. The original transcript stays intact.
        for (const evidence of point.evidence) {
          for (const text of pieces(point.text, 1000))
            for (const quote of pieces(evidence.quote, 300).filter(
              (part) => part.trim().length >= 3,
            ))
              rows.push(
                JSON.stringify({
                  kind,
                  key: `${index}:${kind}:${pointIndex}`,
                  text,
                  ...("title" in point ? { title: point.title } : {}),
                  ...("owner" in point && "due" in point
                    ? { owner: point.owner, due: point.due }
                    : {}),
                  evidence: [{ source: evidence.source, quote }],
                }),
              );
        }
      }
    }
  const batches: string[] = [];
  let batch = MERGE_INSTRUCTION;
  for (const row of rows) {
    if (MERGE_INSTRUCTION.length + row.length + 1 > budget)
      throw new APIError(
        "Пункт резюме превышает контекст модели. Исходная запись сохранена.",
      );
    if (batch.length + row.length + 1 > budget) {
      batches.push(batch);
      batch = MERGE_INSTRUCTION;
    }
    batch += row + "\n";
  }
  if (batch !== MERGE_INSTRUCTION) batches.push(batch);
  return batches;
}

export class ProcessingQueue {
  private jobs = new Map<string, AbortController>();
  private suspended = new Set<string>();
  private closed = false;
  private localJobs = new Map<string, "transcribe" | "brief">();
  private timer: ReturnType<typeof setInterval>;
  constructor(
    private store: MeetingStore,
    private api: Pick<OpenAIClient, "transcribe" | "brief">,
    private enabled: (settings: Settings) => boolean,
    private changed: () => void,
  ) {
    this.timer = setInterval(() => this.tick(), 700);
    this.timer.unref();
  }
  private tick(): void {
    if (this.closed) return;
    const candidates = [...this.store.meetings.values()]
      .filter(
        (m) =>
          !this.suspended.has(m.id) &&
          !this.jobs.has(m.id) &&
          this.enabled(m.settings) &&
          (local(m.settings) || m.settings.cloudConsent) &&
          (m.status === "captured" ||
            m.status === "processing" ||
            m.status === "recording"),
      )
      .sort(
        (a, b) =>
          Number(b.status === "recording") - Number(a.status === "recording"),
      );
    for (const m of candidates) {
      // One live capture may use a reserved third slot while two remote summaries finish.
      if (
        this.jobs.size >= 3 ||
        (this.jobs.size >= 2 && m.status !== "recording")
      )
        break;
      if (
        m.status === "recording" &&
        !m.chunks.some((c) => c.text === undefined)
      )
        continue;
      const kind = m.chunks.some((c) => c.text === undefined)
        ? "transcribe"
        : "brief";
      // A single CPU LLM and a single ASR may run together; multiple 4B models never compete for RAM.
      if (local(m.settings)) {
        if ([...this.localJobs.values()].includes(kind)) continue;
        this.localJobs.set(m.id, kind);
      }
      const controller = new AbortController();
      this.jobs.set(m.id, controller);
      void this.process(m, controller.signal)
        .catch((error) => {
          if (controller.signal.aborted) return;
          const message =
            error instanceof Error
              ? error.message
              : "Не удалось обработать встречу.";
          m.error = message;
          // Preserve capture state and audio even if AI fails mid-recording.
          if (m.status !== "recording") m.status = "error";
          this.suspended.add(m.id);
          try {
            this.store.save(m);
          } catch {
            m.error =
              "Не удалось сохранить состояние обработки. Проверьте свободное место; исходное аудио сохранено.";
          }
        })
        .finally(() => {
          this.jobs.delete(m.id);
          this.localJobs.delete(m.id);
          this.changed();
        });
    }
  }
  private async process(m: Meeting, signal: AbortSignal): Promise<void> {
    const pending = m.chunks.find((c) => c.text === undefined);
    if (pending) {
      if (m.status !== "recording") m.status = "processing";
      this.store.save(m);
      this.changed();
      const index = m.chunks.indexOf(pending);
      const previous =
        m.chunks
          .slice(0, index)
          .reverse()
          .find((c) => c.text)?.text ?? "";
      const result = await this.api.transcribe(
        this.store.audio(m.id, pending),
        m.settings,
        previous,
        signal,
      );
      signal.throwIfAborted();
      pending.text = result;
      m.error = undefined;
      this.store.save(m);
      return;
    }
    if (m.status === "recording") return;
    m.status = "processing";
    this.store.save(m);
    this.changed();
    const budget = local(m.settings) ? 6000 : 20000;
    const batches = sourceBatches(m.chunks, budget);
    let finalBrief: Brief;
    if (!batches.length) {
      finalBrief = {
        overview: "В записи не обнаружена речь.",
        topics: [],
        decisions: [],
        actions: [],
        questions: [],
      };
    } else {
      let briefs: Brief[] = [];
      for (const input of batches)
        briefs.push(await this.cachedBrief(input, m, signal));
      let stalled = 0,
        rounds = 0;
      while (briefs.length > 1) {
        if (++rounds > 12)
          throw new APIError(
            "Модель не смогла сократить длинное резюме. Расшифровка и промежуточные результаты сохранены.",
          );
        const next: Brief[] = [];
        const merged = reductionBatches(briefs, budget);
        if (!merged.length) {
          briefs = [briefs[0]!];
          break;
        }
        for (const input of merged)
          next.push(await this.cachedBrief(input, m, signal));
        stalled = next.length >= briefs.length ? stalled + 1 : 0;
        if (stalled >= 3)
          throw new APIError(
            "Модель возвращает слишком подробный ответ. Расшифровка и промежуточные результаты сохранены.",
          );
        briefs = next;
      }
      finalBrief = briefs[0]!;
    }
    signal.throwIfAborted();
    m.brief = finalBrief;
    m.summaryModelUsed = local(m.settings)
      ? LOCAL_SUMMARY_MODEL
      : m.settings.summaryModel;
    m.status = "ready";
    m.error = undefined;
    this.store.save(m);
  }
  private async cachedBrief(
    input: string,
    m: Meeting,
    signal: AbortSignal,
  ): Promise<Brief> {
    signal.throwIfAborted();
    const hash = createHash("sha256")
      .update(
        JSON.stringify([
          3,
          m.title,
          m.project,
          m.settings.provider ?? "openai",
          local(m.settings) ? LOCAL_SUMMARY_MODEL : m.settings.summaryModel,
          input,
        ]),
      )
      .digest("hex");
    const filename = path.join(
      this.store.directory(m.id),
      "cache",
      `${hash}.json`,
    );
    if (fs.existsSync(filename)) {
      try {
        if (fs.statSync(filename).size > 1024 * 1024)
          throw new Error("Oversized cache");
        return validateInputEvidence(
          validateBrief(
            JSON.parse(fs.readFileSync(filename, "utf8")),
            m.chunks,
          ),
          input,
        );
      } catch {
        /* Corrupt/obsolete cache is regenerated, source is untouched. */
      }
    }
    const brief = await this.api.brief(input, m, signal);
    signal.throwIfAborted();
    atomicJSON(filename, brief);
    return brief;
  }
  pause(meetingID: string): void {
    const m = this.store.get(meetingID);
    this.suspended.add(meetingID);
    this.jobs.get(meetingID)?.abort();
    if (m.status !== "recording") m.status = "paused";
    this.store.save(m);
    this.changed();
  }
  resume(meetingID: string): void {
    const m = this.store.get(meetingID);
    if (this.jobs.has(meetingID))
      throw new Error("Дождитесь остановки текущей операции.");
    this.suspended.delete(meetingID);
    m.error = undefined;
    if (m.status !== "recording") m.status = "captured";
    this.store.save(m);
    this.tick();
    this.changed();
  }
  busy(meetingID: string): boolean {
    return this.jobs.has(meetingID);
  }
  async shutdown(): Promise<void> {
    this.closed = true;
    clearInterval(this.timer);
    for (const controller of this.jobs.values()) controller.abort();
    // Aborts settle promptly; callers retain source and cached successful work.
    for (let i = 0; this.jobs.size && i < 50; i++)
      await new Promise((resolve) => setTimeout(resolve, 20));
  }
  revokeConsent(): void {
    for (const m of this.store.meetings.values())
      if (
        !local(m.settings) &&
        (this.jobs.has(m.id) || m.status === "captured")
      )
        this.pause(m.id);
  }
}
