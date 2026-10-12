import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import type {
  Chunk,
  Meeting,
  MeetingInfo,
  RecordingOptions,
  Settings,
} from "../contracts";
import { id, storedMeeting } from "./validation";
import { MAX_SAMPLES, MIN_SAMPLES, SAMPLE_RATE, pcmStats, wav } from "./audio";

export function atomicJSON(filename: string, data: unknown): void {
  fs.mkdirSync(path.dirname(filename), { recursive: true, mode: 0o700 });
  const temporary = `${filename}.${randomUUID()}.tmp`;
  const fd = fs.openSync(temporary, "wx", 0o600);
  try {
    try {
      fs.writeFileSync(fd, JSON.stringify(data));
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(temporary, filename);
  } catch (error) {
    fs.rmSync(temporary, { force: true });
    throw error;
  }
}

/** Audio is journaled before acknowledgment. A crash loses only the IPC buffer in flight. */
export class MeetingStore {
  readonly meetings = new Map<string, Meeting>();
  activeID: string | null = null;
  private pcmFD: number | null = null;
  private samples = 0;
  private silentSamples = 0;
  private lastSync = 0;
  private damaged = new Set<string>();
  constructor(readonly root: string) {
    fs.mkdirSync(root, { recursive: true, mode: 0o700 });
    for (const entry of fs.readdirSync(root, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      try {
        id(entry.name);
      } catch {
        continue;
      }
      const filename = path.join(root, entry.name, "meeting.json");
      try {
        if (fs.statSync(filename).size > 16 * 1024 * 1024)
          throw new Error("Meeting exceeds safe metadata size");
        const m = storedMeeting(JSON.parse(fs.readFileSync(filename, "utf8")));
        if (
          m.schema !== 1 ||
          id(m.id) !== entry.name ||
          !Array.isArray(m.chunks)
        )
          throw new Error("Invalid meeting metadata");
        this.meetings.set(m.id, m);
        const pending = path.join(this.directory(m.id), "current.pcm");
        if (fs.existsSync(pending) && fs.statSync(pending).size > 0)
          this.recoverPCM(m, pending);
        if (m.status === "recording" || m.status === "processing") {
          m.status = "interrupted";
          m.capturePaused = false;
          m.error =
            "Приложение было закрыто. Материалы сохранены; продолжите обработку.";
          this.save(m);
        }
      } catch {
        // Never overwrite or delete damaged data. Surface a recoverable library entry.
        const m: Meeting = {
          schema: 1,
          id: entry.name,
          title: "Повреждённая запись",
          project: "",
          startedAt: new Date(0).toISOString(),
          duration: 0,
          status: "error",
          chunks: [],
          notes: "",
          bookmarks: [],
          tasks: [],
          settings: {
            transcriptionModel: "gpt-4o-transcribe",
            summaryModel: "gpt-5.4",
            language: "ru",
            glossary: "",
            cloudConsent: false,
          },
          source: "microphone",
          error: "Файл встречи повреждён. Исходные файлы сохранены на диске.",
        };
        this.meetings.set(m.id, m);
        this.damaged.add(m.id);
      }
    }
  }
  directory(meetingID: string): string {
    return path.join(this.root, id(meetingID));
  }
  isDamaged(meetingID: string): boolean {
    return this.damaged.has(id(meetingID));
  }
  /** Library inspection also exposes damaged entries, but editing/processing remain blocked. */
  inspect(meetingID: string): Meeting {
    const m = this.meetings.get(id(meetingID));
    if (!m) throw new Error("Встреча не найдена.");
    return m;
  }
  get(meetingID: string): Meeting {
    if (this.isDamaged(meetingID))
      throw new Error(
        "Метаданные повреждены. Исходные файлы не изменялись; восстановите их из резервной копии.",
      );
    return this.inspect(meetingID);
  }
  list(): MeetingInfo[] {
    return [...this.meetings.values()]
      .sort((a, b) => b.startedAt.localeCompare(a.startedAt))
      .map((m) => {
        const { chunks, brief, notes, bookmarks, settings, ...info } = m;
        return {
          ...info,
          chunkCount: chunks.length,
          completedChunks: chunks.filter((c) => c.text !== undefined).length,
        };
      });
  }
  save(meeting: Meeting): void {
    if (this.isDamaged(meeting.id))
      throw new Error("Повреждённые метаданные защищены от перезаписи.");
    atomicJSON(path.join(this.directory(meeting.id), "meeting.json"), meeting);
  }
  create(options: RecordingOptions, settings: Settings): Meeting {
    if (this.activeID) throw new Error("Сначала завершите текущую запись.");
    const space = fs.statfsSync(this.root);
    if (space.bavail * space.bsize < 300 * 1024 * 1024)
      throw new Error("Для записи нужно не менее 300 МБ свободного места.");
    const m: Meeting = {
      schema: 1,
      id: randomUUID(),
      title: options.title.trim() || "Новая встреча",
      project: options.project.trim(),
      startedAt: new Date().toISOString(),
      duration: 0,
      status: "recording",
      chunks: [],
      notes: "",
      bookmarks: [],
      tasks: [],
      settings: { ...settings },
      source: options.systemAudio ? "microphone+system" : "microphone",
    };
    fs.mkdirSync(path.join(this.directory(m.id), "chunks"), {
      recursive: true,
      mode: 0o700,
    });
    this.save(m);
    atomicJSON(path.join(this.directory(m.id), "journal.json"), { start: 0 });
    this.meetings.set(m.id, m);
    this.activeID = m.id;
    this.samples = 0;
    this.silentSamples = 0;
    this.pcmFD = fs.openSync(
      path.join(this.directory(m.id), "current.pcm"),
      "w",
      0o600,
    );
    return m;
  }
  append(meetingID: string, pcm: Buffer): void {
    const m = this.get(meetingID);
    if (this.activeID !== meetingID || m.capturePaused || this.pcmFD === null)
      throw new Error("Запись не активна.");
    if (pcm.length > 65536 || pcm.length % 2)
      throw new Error("Некорректный аудиобуфер.");
    let offset = 0;
    while (offset < pcm.length) {
      const take = Math.min(
        pcm.length - offset,
        (MAX_SAMPLES - this.samples) * 2,
      );
      const part = pcm.subarray(offset, offset + take);
      fs.writeFileSync(this.pcmFD!, part);
      this.samples += take / 2;
      offset += take;
      this.silentSamples =
        pcmStats(part).rms < 0.004 ? this.silentSamples + take / 2 : 0;
      if (
        this.samples >= MAX_SAMPLES ||
        (this.samples >= MIN_SAMPLES && this.silentSamples >= SAMPLE_RATE * 0.5)
      )
        this.flush(m);
    }
    if (Date.now() - this.lastSync > 2000 && this.pcmFD !== null) {
      fs.fsyncSync(this.pcmFD);
      this.lastSync = Date.now();
      const space = fs.statfsSync(this.root);
      if (space.bavail * space.bsize < 50 * 1024 * 1024)
        throw new Error(
          "На диске осталось мало места. Запись остановлена; сохранённые материалы доступны.",
        );
    }
  }
  private persistChunk(m: Meeting, pcm: Buffer): void {
    if (!pcm.length) return;
    const stats = pcmStats(pcm);
    const chunk: Chunk = {
      id: randomUUID(),
      start: m.duration,
      duration: pcm.length / 2 / SAMPLE_RATE,
      samples: pcm.length / 2,
      voiced: stats.peak >= 0.0005,
    };
    if (!chunk.voiced) chunk.text = "";
    fs.mkdirSync(path.join(this.directory(m.id), "chunks"), {
      recursive: true,
      mode: 0o700,
    });
    const filename = path.join(
      this.directory(m.id),
      "chunks",
      `${chunk.id}.wav`,
    );
    const fd = fs.openSync(filename, "wx", 0o600);
    try {
      fs.writeFileSync(fd, wav(pcm));
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    m.chunks.push(chunk);
    m.duration += chunk.duration;
    this.save(m);
  }
  private recoverPCM(m: Meeting, filename: string): void {
    if (fs.statSync(filename).size > MAX_SAMPLES * 2 * 4)
      throw new Error("Recovery journal exceeds capture bounds");
    const pcm = fs.readFileSync(filename);
    const valid = pcm.length - (pcm.length % 2);
    // A crash after metadata commit but before journal truncation must not duplicate audio.
    const journalInfo = path.join(this.directory(m.id), "journal.json");
    const start = fs.existsSync(journalInfo)
      ? (JSON.parse(fs.readFileSync(journalInfo, "utf8")).start as number)
      : m.duration;
    if (!Number.isFinite(start) || start < 0 || start > m.duration)
      throw new Error("Invalid recovery journal");
    const skip =
      Math.max(0, Math.round((m.duration - start) * SAMPLE_RATE)) * 2;
    if (skip > valid + 2)
      throw new Error("Recovery journal does not match committed audio");
    for (let pos = skip; pos < valid; pos += MAX_SAMPLES * 2)
      this.persistChunk(
        m,
        pcm.subarray(pos, Math.min(valid, pos + MAX_SAMPLES * 2)),
      );
    fs.truncateSync(filename, 0);
  }
  private flush(m: Meeting): void {
    if (this.pcmFD === null || !this.samples) return;
    fs.fsyncSync(this.pcmFD);
    fs.closeSync(this.pcmFD);
    this.pcmFD = null;
    const filename = path.join(this.directory(m.id), "current.pcm");
    this.persistChunk(m, fs.readFileSync(filename));
    this.pcmFD = fs.openSync(filename, "w", 0o600);
    this.samples = 0;
    this.silentSamples = 0;
    atomicJSON(path.join(this.directory(m.id), "journal.json"), {
      start: m.duration,
    });
  }
  pause(meetingID: string, paused: boolean): void {
    if (this.activeID !== meetingID) throw new Error("Запись не активна.");
    const m = this.get(meetingID);
    this.flush(m);
    m.capturePaused = paused;
    this.save(m);
  }
  stop(meetingID: string): void {
    if (this.activeID !== meetingID) throw new Error("Запись не активна.");
    const m = this.get(meetingID);
    this.flush(m);
    if (this.pcmFD !== null) fs.closeSync(this.pcmFD);
    this.pcmFD = null;
    this.activeID = null;
    m.capturePaused = false;
    m.status = "captured";
    this.save(m);
  }
  elapsed(meetingID: string): number {
    return (
      this.get(meetingID).duration +
      (this.activeID === meetingID ? this.samples / SAMPLE_RATE : 0)
    );
  }
  audio(meetingID: string, chunk: Chunk): Buffer {
    return fs.readFileSync(
      path.join(this.directory(meetingID), "chunks", `${id(chunk.id)}.wav`),
    );
  }
  forget(meetingID: string): void {
    if (this.activeID === meetingID)
      throw new Error("Сначала завершите запись.");
    this.meetings.delete(id(meetingID));
    this.damaged.delete(meetingID);
  }
}
