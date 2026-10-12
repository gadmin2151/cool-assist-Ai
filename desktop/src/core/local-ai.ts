import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { spawn } from "node:child_process";
import type { Brief, Meeting, Settings } from "../contracts";
import { MAX_SAMPLES, SAMPLE_RATE } from "./audio";
import {
  APIError,
  BRIEF_INSTRUCTIONS,
  BRIEF_SCHEMA,
  validateBrief,
  validateInputEvidence,
} from "./openai";

export interface LocalAIOptions {
  whisperExecutable: string;
  llamaExecutable: string;
  whisperModel: string;
  vadModel?: string;
  summaryModel: string;
  temporaryRoot: string;
  threads?: number;
}
export interface LocalProcessRequest {
  executable: string;
  args: string[];
  cwd: string;
  signal: AbortSignal;
  timeoutMs: number;
  maxOutputBytes: number;
}
export type LocalProcessRunner = (
  request: LocalProcessRequest,
) => Promise<Buffer>;

/** No shell, no prompt in logs, bounded output, and cancellation kills the actual worker. */
export const runLocalProcess: LocalProcessRunner = (request) =>
  new Promise((resolve, reject) => {
    request.signal.throwIfAborted();
    const child = spawn(request.executable, request.args, {
      cwd: request.cwd,
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    const output: Buffer[] = [];
    let bytes = 0,
      failure: Error | undefined,
      killTimer: ReturnType<typeof setTimeout> | undefined;
    const stop = (error: Error) => {
      if (failure) return;
      failure = error;
      child.kill("SIGTERM");
      killTimer = setTimeout(() => child.kill("SIGKILL"), 1500);
      killTimer.unref();
    };
    const abort = () =>
      stop(new DOMException("Операция отменена.", "AbortError"));
    const timer = setTimeout(
      () =>
        stop(
          new APIError(
            "Локальная обработка заняла слишком много времени. Аудио сохранено; повторите обработку.",
          ),
        ),
      request.timeoutMs,
    );
    timer.unref();
    request.signal.addEventListener("abort", abort, { once: true });
    if (request.signal.aborted) abort();
    child.stdout.on("data", (data: Buffer) => {
      bytes += data.length;
      if (bytes > request.maxOutputBytes)
        stop(
          new APIError(
            "Локальная модель превысила размер ответа. Исходная запись сохранена.",
          ),
        );
      else output.push(data);
    });
    // Drain diagnostic output without retaining it: runtimes may print the prompt or decoded speech.
    child.stderr.resume();
    child.once("error", () => {
      failure ??= new APIError(
        "Не удалось запустить локальную модель. Проверьте установку AI в настройках.",
      );
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (killTimer) clearTimeout(killTimer);
      request.signal.removeEventListener("abort", abort);
      if (failure) reject(failure);
      else if (code !== 0)
        reject(
          new APIError(
            `Локальная модель завершилась с кодом ${code ?? "—"}. Проверьте свободную память и установку AI.`,
          ),
        );
      else resolve(Buffer.concat(output));
    });
  });

function inferenceThreads(value: number | undefined): number {
  return Number.isInteger(value) && value! >= 1 && value! <= 16
    ? value!
    : Math.max(1, Math.min(4, os.availableParallelism() - 1));
}
function promptData(value: string): string {
  return value.replace(/<\|/g, "< |");
}
async function existingFile(filename: string, label: string): Promise<void> {
  if (!path.isAbsolute(filename))
    throw new APIError(
      `Не установлен ${label}. Откройте настройки локального AI.`,
    );
  try {
    if (!(await fs.stat(filename)).isFile()) throw new Error();
  } catch {
    throw new APIError(
      `Не установлен ${label}. Откройте настройки локального AI.`,
    );
  }
}

function normalized(value: string): string {
  return value.toLocaleLowerCase().replace(/\s+/g, " ").trim();
}

function exactQuoteCandidates(text: string): string[] {
  const candidates = new Set<string>();
  // Include short sentences and bounded consecutive passages, always cut from the original.
  for (const sentence of [
    text,
    ...Array.from(text.matchAll(/[^.!?\n]+[.!?]?/gu), (match) => match[0]),
  ]) {
    for (let start = 0; start < sentence.length; ) {
      let end = Math.min(sentence.length, start + 240);
      if (end < sentence.length) {
        const boundary = sentence.lastIndexOf(" ", end);
        if (boundary > start + 120) end = boundary + 1;
        const previous = sentence.charCodeAt(end - 1);
        if (previous >= 0xd800 && previous <= 0xdbff) end--;
      }
      const quote = sentence.slice(start, end).trim();
      if (quote.length >= 3) candidates.add(quote);
      start = end;
    }
  }
  return [...candidates];
}

export function localBriefSchema(meeting: Meeting, input: string) {
  const sources = meeting.chunks.filter((chunk) => input.includes(chunk.id));
  if (!sources.length)
    throw new APIError("В текущем фрагменте нет источников для резюме.");
  const visible = normalized(input);
  const evidenceOptions = sources.flatMap((chunk) => {
    const quotes = exactQuoteCandidates(chunk.text ?? "").filter(
      (quote) =>
        visible.includes(normalized(quote)) ||
        visible.includes(normalized(JSON.stringify(quote).slice(1, -1))),
    );
    return quotes.length
      ? [
          {
            type: "object",
            properties: {
              source: { type: "string", const: chunk.id },
              quote: { type: "string", enum: quotes },
            },
            required: ["source", "quote"],
            additionalProperties: false,
          },
        ]
      : [];
  });
  const schema = structuredClone(BRIEF_SCHEMA);
  Object.assign(schema.properties.overview, { minLength: 1, maxLength: 900 });
  for (const key of ["topics", "decisions", "actions", "questions"] as const) {
    const group = schema.properties[key];
    Object.assign(group, {
      maxItems: evidenceOptions.length ? (key === "topics" ? 12 : 20) : 0,
    });
    Object.assign(group.items.properties.text, {
      minLength: 1,
      maxLength: 1200,
    });
    const evidence = group.items.properties.evidence;
    Object.assign(evidence, { minItems: 1, maxItems: 3 });
    if (evidenceOptions.length)
      Object.assign(evidence, { items: { anyOf: evidenceOptions } });
  }
  return schema;
}

/** Compatible with the cloud provider; recording and queue never depend on an API key. */
export class LocalAIClient {
  constructor(
    private configuration: LocalAIOptions | (() => LocalAIOptions),
    private runner: LocalProcessRunner = runLocalProcess,
  ) {}
  private options(): LocalAIOptions {
    return typeof this.configuration === "function"
      ? this.configuration()
      : this.configuration;
  }
  private async temporary<T>(
    options: LocalAIOptions,
    signal: AbortSignal,
    run: (directory: string) => Promise<T>,
  ): Promise<T> {
    signal.throwIfAborted();
    if (!path.isAbsolute(options.temporaryRoot))
      throw new APIError("Некорректная папка локального AI.");
    await fs.mkdir(options.temporaryRoot, { recursive: true, mode: 0o700 });
    const directory = await fs.mkdtemp(
      path.join(options.temporaryRoot, "inference-"),
    );
    try {
      signal.throwIfAborted();
      return await run(directory);
    } finally {
      await fs.rm(directory, { recursive: true, force: true });
    }
  }
  async transcribe(
    audio: Buffer,
    settings: Settings,
    _previous: string,
    signal: AbortSignal,
  ): Promise<string> {
    // Store-generated WAV is mono signed PCM16 at 16 kHz; reject malformed input before invoking a binary.
    if (
      audio.length < 44 ||
      audio.length > MAX_SAMPLES * 2 + 44 ||
      audio.toString("ascii", 0, 4) !== "RIFF" ||
      audio.toString("ascii", 8, 12) !== "WAVE" ||
      audio.readUInt16LE(20) !== 1 ||
      audio.readUInt16LE(22) !== 1 ||
      audio.readUInt32LE(24) !== SAMPLE_RATE ||
      audio.readUInt16LE(34) !== 16 ||
      audio.readUInt32LE(40) !== audio.length - 44 ||
      (audio.length - 44) % 2
    )
      throw new APIError(
        "Некорректный аудиофрагмент. Исходная запись сохранена.",
      );
    const options = this.options();
    await existingFile(options.whisperExecutable, "модуль распознавания");
    await existingFile(options.whisperModel, "модель распознавания");
    if (options.vadModel) await existingFile(options.vadModel, "детектор речи");
    return this.temporary(options, signal, async (directory) => {
      const filename = path.join(directory, "speech.wav"),
        output = path.join(directory, "recognized");
      await fs.writeFile(filename, audio, { mode: 0o600 });
      const args = [
        "-m",
        options.whisperModel,
        "-f",
        filename,
        "-l",
        settings.language,
        "-oj",
        "-of",
        output,
        "-np",
        "-ng",
        "-t",
        String(inferenceThreads(options.threads)),
        "-bs",
        "3",
        "-sns",
      ];
      if (options.vadModel)
        args.push(
          "--vad",
          "-vm",
          options.vadModel,
          "--vad-speech-pad-ms",
          "200",
        );
      // Terminology is a hint, not a reused transcript: do not carry old speech into a silent chunk.
      if (settings.glossary.trim())
        args.push(
          "--prompt",
          promptData(settings.glossary.trim().slice(0, 1200)),
        );
      await this.runner({
        executable: options.whisperExecutable,
        args,
        cwd: directory,
        signal,
        timeoutMs: 240000,
        maxOutputBytes: 1024 * 1024,
      });
      signal.throwIfAborted();
      const resultFile = output + ".json";
      if ((await fs.stat(resultFile)).size > 1024 * 1024)
        throw new APIError("Модель вернула слишком большую расшифровку.");
      let data: unknown;
      try {
        data = JSON.parse(await fs.readFile(resultFile, "utf8"));
      } catch {
        throw new APIError("Не удалось прочитать локальную расшифровку.");
      }
      return localTranscript(data, (audio.length - 44) / 2 / SAMPLE_RATE);
    });
  }
  async brief(
    input: string,
    meeting: Meeting,
    signal: AbortSignal,
  ): Promise<Brief> {
    if (input.length > 6000)
      throw new APIError(
        "Превышен контекст локальной модели. Разделите обработку на фрагменты.",
      );
    const options = this.options();
    await existingFile(options.llamaExecutable, "модуль резюме");
    await existingFile(options.summaryModel, "модель резюме");
    return this.temporary(options, signal, async (directory) => {
      const prompt = path.join(directory, "prompt.txt");
      const thinking = path
        .basename(options.summaryModel)
        .includes("Instruct-2507")
        ? ""
        : "<think>\n\n</think>\n\n";
      const content = `<|im_start|>system\n${BRIEF_INSTRUCTIONS}\nВерни только JSON по схеме. Категории без подтверждённых пунктов возвращай пустыми массивами [], без заглушек «не указано». Каждый включённый пункт требует хотя бы одну дословную цитату. Не рассуждай. /no_think<|im_end|>\n<|im_start|>user\nНазвание: ${promptData(meeting.title)}\nПроект: ${promptData(meeting.project)}\nДанные встречи:\n${promptData(input)}<|im_end|>\n<|im_start|>assistant\n${thinking}`;
      await fs.writeFile(prompt, content, { mode: 0o600 });
      // A file avoids the Windows command-line size limit and keeps quoted speech out of process arguments.
      const schemaFile = path.join(directory, "schema.json");
      await fs.writeFile(
        schemaFile,
        JSON.stringify(localBriefSchema(meeting, input)),
        { mode: 0o600 },
      );
      const args = [
        "-m",
        options.summaryModel,
        "-f",
        prompt,
        "-n",
        "2600",
        "-c",
        "8192",
        "-ngl",
        "0",
        // Each short-lived job loads weights once; avoid a second multi-GB repacked copy.
        "--no-repack",
        "--no-op-offload",
        "-t",
        String(inferenceThreads(options.threads)),
        "--temp",
        "0.1",
        "--top-p",
        "0.8",
        "--top-k",
        "20",
        "--seed",
        "42",
        "--no-display-prompt",
        "--no-conversation",
        "--simple-io",
        "--repeat-penalty",
        "1",
        "--presence-penalty",
        "0",
        "-r",
        "<|im_end|>",
        "--json-schema-file",
        schemaFile,
      ];
      const result = await this.runner({
        executable: options.llamaExecutable,
        args,
        cwd: directory,
        signal,
        timeoutMs: 1200000,
        maxOutputBytes: 1024 * 1024,
      });
      signal.throwIfAborted();
      const raw = result
        .toString("utf8")
        .replace(/\[end of text\]|<\|im_end\|>/g, "")
        .trim();
      let parsed: unknown;
      try {
        parsed = JSON.parse(raw);
      } catch {
        throw new APIError(
          "Локальная модель не завершила резюме. Материалы сохранены; повторите обработку.",
        );
      }
      return validateInputEvidence(
        validateBrief(parsed, meeting.chunks),
        input,
      );
    });
  }
}

export function localTranscript(value: unknown, duration: number): string {
  if (
    !value ||
    typeof value !== "object" ||
    !Array.isArray((value as { transcription?: unknown }).transcription)
  )
    throw new APIError("Некорректный ответ локального распознавания.");
  const rows = (value as { transcription: unknown[] }).transcription;
  if (rows.length > 1000 || !Number.isFinite(duration) || duration < 0)
    throw new APIError("Некорректная локальная расшифровка.");
  const texts: string[] = [];
  for (const item of rows) {
    if (!item || typeof item !== "object")
      throw new APIError("Некорректная локальная расшифровка.");
    const row = item as {
      text?: unknown;
      offsets?: { from?: unknown; to?: unknown };
    };
    if (typeof row.text !== "string" || row.text.length > 30000)
      throw new APIError("Некорректная локальная расшифровка.");
    const from = row.offsets?.from,
      to = row.offsets?.to;
    if (
      typeof from !== "number" ||
      typeof to !== "number" ||
      !Number.isFinite(from) ||
      !Number.isFinite(to) ||
      from < 0 ||
      to < from
    )
      throw new APIError("Некорректное время локальной расшифровки.");
    const text = row.text.trim();
    if (
      from >= duration * 1000 ||
      to <= 0 ||
      !text ||
      /^\[(BLANK_AUDIO|NO_SPEECH)\]$/i.test(text)
    )
      continue;
    texts.push(text);
  }
  const result = texts.join(" ").trim();
  if (result.length > 30000)
    throw new APIError("Локальная расшифровка превышает размер фрагмента.");
  return result;
}
