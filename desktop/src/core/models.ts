import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import type { LocalModelState } from "../contracts";

export interface ModelAsset {
  name: string;
  label: string;
  bytes: number;
  sha256: string;
  url: string;
}
const ASSETS: readonly ModelAsset[] = [
  {
    name: "ggml-small-q5_1.bin",
    label: "Whisper Small · распознавание",
    bytes: 190085487,
    sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
    url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin",
  },
  {
    name: "ggml-silero-v6.2.0.bin",
    label: "Silero · выделение речи",
    bytes: 885098,
    sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
    url: "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin",
  },
  {
    name: "Qwen3-4B-Q4_K_M.gguf",
    label: "Qwen3 4B · резюме",
    bytes: 2497280256,
    sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
    url: "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf",
  },
] as const;

export class LocalModels {
  private verified = new Set<string>();
  private controller: AbortController | null = null;
  private progress = 0;
  private active = "";
  private error: string | undefined;
  private checking = true;
  constructor(
    readonly root: string,
    private changed: () => void,
    private assets: readonly ModelAsset[] = ASSETS,
    private transport: typeof fetch = fetch,
  ) {
    fs.mkdirSync(root, { recursive: true, mode: 0o700 });
    void this.inspect()
      .catch(() => {
        this.error = "Не удалось проверить модели. Повторите загрузку.";
      })
      .finally(() => {
        this.checking = false;
        this.changed();
      });
  }
  private async digest(
    filename: string,
    signal?: AbortSignal,
  ): Promise<string> {
    const hash = createHash("sha256");
    for await (const bytes of fs.createReadStream(filename)) {
      signal?.throwIfAborted();
      hash.update(bytes);
    }
    return hash.digest("hex");
  }
  private async inspect(): Promise<void> {
    for (const asset of this.assets) {
      const filename = path.join(this.root, asset.name);
      if (
        fs.existsSync(filename) &&
        fs.statSync(filename).size === asset.bytes &&
        (await this.digest(filename)) === asset.sha256
      )
        this.verified.add(asset.name);
    }
  }
  state(): LocalModelState {
    return {
      ready: this.verified.size === this.assets.length,
      checking: this.checking,
      downloading: Boolean(this.controller),
      active: this.active,
      downloaded: this.progress,
      total: this.assets.reduce((n, a) => n + a.bytes, 0),
      completed: this.assets
        .filter((a) => this.verified.has(a.name))
        .reduce((n, a) => n + a.bytes, 0),
      error: this.error,
    };
  }
  paths(): { whisperModel: string; vadModel: string; summaryModel: string } {
    if (!this.state().ready)
      throw new Error("Сначала скачайте локальные модели в настройках.");
    return {
      whisperModel: path.join(this.root, this.assets[0]!.name),
      vadModel: path.join(this.root, this.assets[1]!.name),
      summaryModel: path.join(this.root, this.assets[2]!.name),
    };
  }
  start(): void {
    if (this.controller || this.checking)
      throw new Error("Дождитесь текущей проверки или загрузки.");
    const needed = this.assets
      .filter((a) => !this.verified.has(a.name))
      .reduce((n, a) => {
        const partial = path.join(this.root, a.name + ".partial");
        const bytes = fs.existsSync(partial)
          ? Math.min(a.bytes, fs.statSync(partial).size)
          : 0;
        return n + a.bytes - bytes;
      }, 0);
    const space = fs.statfsSync(this.root);
    if (space.bavail * space.bsize < needed + 512 * 1024 * 1024)
      throw new Error(
        "Недостаточно места. Для моделей требуется около 3 ГБ и 512 МБ запаса.",
      );
    const controller = new AbortController();
    this.controller = controller;
    this.error = undefined;
    void this.download(controller.signal)
      .catch(() => {
        this.error = controller.signal.aborted
          ? "Загрузка остановлена. Её можно продолжить."
          : "Не удалось загрузить и проверить модели. Проверьте сеть и свободное место, затем продолжите.";
      })
      .finally(() => {
        this.controller = null;
        this.progress = 0;
        this.active = "";
        this.changed();
      });
    this.changed();
  }
  cancel(): void {
    this.controller?.abort();
  }
  private async download(signal: AbortSignal): Promise<void> {
    for (const asset of this.assets) {
      signal.throwIfAborted();
      if (this.verified.has(asset.name)) continue;
      this.active = asset.label;
      this.progress = 0;
      this.changed();
      const target = path.join(this.root, asset.name);
      const partial = target + ".partial";
      let offset = fs.existsSync(partial) ? fs.statSync(partial).size : 0;
      if (offset > asset.bytes) {
        fs.truncateSync(partial, 0);
        offset = 0;
      }
      if (offset < asset.bytes) {
        const response = await this.transport(asset.url, {
          headers: offset ? { Range: `bytes=${offset}-` } : {},
          signal: AbortSignal.any([signal, AbortSignal.timeout(1800000)]),
        });
        if (!response.ok || !response.body)
          throw new Error("Model download failed");
        if (offset && response.status !== 206) offset = 0;
        if (
          response.status === 206 &&
          !response.headers.get("content-range")?.startsWith(`bytes ${offset}-`)
        )
          throw new Error("Invalid download range");
        const fd = fs.openSync(partial, offset ? "a" : "w", 0o600);
        const reader = response.body.getReader();
        let last = 0;
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            signal.throwIfAborted();
            const bytes = Buffer.from(value);
            if (offset + bytes.length > asset.bytes)
              throw new Error("Model exceeds expected size");
            let written = 0;
            while (written < bytes.length) {
              const count = fs.writeSync(
                fd,
                bytes,
                written,
                bytes.length - written,
              );
              if (!count) throw new Error("Disk write failed");
              written += count;
            }
            offset += bytes.length;
            this.progress = offset;
            if (Date.now() - last > 400) {
              last = Date.now();
              this.changed();
            }
          }
          fs.fsyncSync(fd);
        } finally {
          await reader.cancel().catch(() => {
            /* Preserve the original read/write error during cleanup. */
          });
          reader.releaseLock();
          fs.closeSync(fd);
        }
      }
      this.active = `Проверка: ${asset.label}`;
      this.changed();
      if (
        offset !== asset.bytes ||
        (await this.digest(partial, signal)) !== asset.sha256
      ) {
        fs.rmSync(partial, { force: true });
        throw new Error("Model checksum mismatch");
      }
      fs.renameSync(partial, target);
      this.verified.add(asset.name);
      this.progress = 0;
      this.changed();
    }
  }
}

export function runtimeExecutable(root: string, filename: string): string {
  // Search only the immutable runtime tree prepared at build time, never the user's PATH.
  function walk(directory: string, depth: number): string | undefined {
    if (depth > 5 || !fs.existsSync(directory)) return;
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (entry.isFile() && entry.name === filename)
        return path.join(directory, entry.name);
      if (entry.isDirectory()) {
        const found = walk(path.join(directory, entry.name), depth + 1);
        if (found) return found;
      }
    }
  }
  const result = walk(root, 0);
  if (!result)
    throw new Error(
      "Локальный движок отсутствует. Переустановите полную версию приложения.",
    );
  return result;
}
