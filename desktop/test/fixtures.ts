import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { TestContext } from "node:test";
import type { Brief, Meeting, Settings } from "../src/contracts";
import { DEFAULT_SETTINGS } from "../src/contracts";
import { MeetingStore } from "../src/core/store";

export const preferences: Settings = {
  ...DEFAULT_SETTINGS,
  provider: "openai",
  cloudConsent: true,
};
export function library(t: TestContext): MeetingStore {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cool-assist-fixture-"));
  const store = new MeetingStore(root);
  t.after(() => {
    if (store.activeID) store.stop(store.activeID);
    fs.rmSync(root, { recursive: true, force: true });
  });
  return store;
}
export function pcm(seconds: number, amplitude = 1000): Buffer {
  const buffer = Buffer.alloc(Math.round(seconds * 16000) * 2);
  for (let i = 0; i < buffer.length; i += 2)
    buffer.writeInt16LE(Math.round(Math.sin(i / 19) * amplitude), i);
  return buffer;
}
export function append(store: MeetingStore, m: Meeting, data: Buffer): void {
  for (let offset = 0; offset < data.length; offset += 65536)
    store.append(m.id, data.subarray(offset, offset + 65536));
}
export function captured(
  store: MeetingStore,
  title = "Синтетическая встреча",
): Meeting {
  const m = store.create(
    { title, project: "Тест", systemAudio: false },
    preferences,
  );
  append(store, m, pcm(1));
  store.stop(m.id);
  return m;
}
export const speech =
  "Бюджет 50 тысяч пока не утверждён. Анна подготовит расчёт к пятнице.";
export function brief(m: Meeting): Brief {
  const c = m.chunks.find((c) => c.text?.trim());
  return {
    overview: "Обсуждались расчёт и бюджет.",
    topics: c
      ? [
          {
            title: "Бюджет",
            text: "Бюджет пока не утверждён.",
            evidence: [{ source: c.id, quote: c.text! }],
          },
        ]
      : [],
    decisions: [],
    actions: [],
    questions: [],
  };
}
export function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}
export async function eventually(
  predicate: () => boolean,
  timeout = 4000,
): Promise<void> {
  const end = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() > end) throw new Error("Timed out waiting for fixture");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
