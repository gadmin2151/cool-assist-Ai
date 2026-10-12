import test from "node:test";
import assert from "node:assert/strict";
import { ProcessingQueue } from "../src/core/queue";
import { sourceBatches } from "../src/core/openai";
import {
  append,
  brief,
  captured,
  deferred,
  eventually,
  library,
  pcm,
  preferences,
  speech,
} from "./fixtures";

test("pause rejects late ASR result; resume reuses saved source and finishes processing", async (t) => {
  const store = library(t),
    m = captured(store),
    original = store.audio(m.id, m.chunks[0]!);
  const first = deferred<string>();
  let calls = 0;
  const queue = new ProcessingQueue(
    store,
    {
      transcribe: async () => (++calls === 1 ? first.promise : speech),
      brief: async (_input, meeting) => brief(meeting),
    },
    () => true,
    () => {},
  );
  t.after(() => queue.shutdown());
  queue.resume(m.id);
  await eventually(() => calls === 1);
  queue.pause(m.id);
  assert.equal(m.status, "paused");
  assert.throws(() => queue.resume(m.id), /Дождитесь/);
  first.resolve("Отменённый результат");
  await eventually(() => !queue.busy(m.id));
  assert.equal(m.chunks[0]!.text, undefined);
  assert.deepEqual(store.audio(m.id, m.chunks[0]!), original);
  queue.resume(m.id);
  await eventually(() => m.status === "ready");
  assert.equal(m.chunks[0]!.text, speech);
  assert.equal(calls, 2);
});

test("failed work is suspended until explicit retry and completed chunks are not retranscribed", async (t) => {
  const store = library(t),
    m = captured(store);
  let calls = 0;
  const queue = new ProcessingQueue(
    store,
    {
      transcribe: async () => {
        if (++calls === 1) throw new Error("Fixture offline");
        return speech;
      },
      brief: async (_input, meeting) => brief(meeting),
    },
    () => true,
    () => {},
  );
  t.after(() => queue.shutdown());
  queue.resume(m.id);
  await eventually(() => m.status === "error");
  await new Promise((resolve) => setTimeout(resolve, 750));
  assert.equal(calls, 1);
  queue.resume(m.id);
  await eventually(() => m.status === "ready");
  queue.resume(m.id);
  await eventually(() => m.status === "ready");
  assert.equal(calls, 2);
});

test("live transcription retains a slot while two background summaries are pending", async (t) => {
  const store = library(t),
    first = captured(store, "One"),
    second = captured(store, "Two");
  first.chunks[0]!.text = speech;
  second.chunks[0]!.text = speech;
  let summaries = 0,
    transcriptions = 0;
  const queue = new ProcessingQueue(
    store,
    {
      transcribe: async () => {
        transcriptions++;
        return speech;
      },
      brief: async (_input, _meeting, signal) => {
        summaries++;
        return new Promise((_, reject) =>
          signal.addEventListener("abort", () => reject(signal.reason), {
            once: true,
          }),
        );
      },
    },
    () => true,
    () => {},
  );
  t.after(() => queue.shutdown());
  queue.resume(first.id);
  await eventually(() => summaries === 2);
  const live = store.create(
    { title: "Live", project: "", systemAudio: false },
    preferences,
  );
  append(store, live, pcm(22));
  queue.resume(live.id);
  await eventually(() => transcriptions === 1);
  assert.equal(live.status, "recording");
  await queue.shutdown();
  assert.equal(queue.busy(first.id), false);
  assert.equal(queue.busy(second.id), false);
});

test("disabled cloud consent prevents requests and revoked consent cancels in-flight work", async (t) => {
  const store = library(t),
    m = captured(store);
  let enabled = false,
    calls = 0;
  const pending = deferred<string>();
  const queue = new ProcessingQueue(
    store,
    {
      transcribe: async () => {
        calls++;
        return pending.promise;
      },
      brief: async (_input, meeting) => brief(meeting),
    },
    () => enabled,
    () => {},
  );
  t.after(() => queue.shutdown());
  queue.resume(m.id);
  assert.equal(calls, 0);
  enabled = true;
  queue.resume(m.id);
  await eventually(() => calls === 1);
  enabled = false;
  queue.revokeConsent();
  pending.resolve(speech);
  await eventually(() => !queue.busy(m.id));
  assert.equal(m.status, "paused");
  assert.equal(m.chunks[0]!.text, undefined);
});

test("retry after partial summary failure reuses successful cached batches", async (t) => {
  const store = library(t),
    m = captured(store);
  m.settings.provider = "local";
  m.chunks[0]!.text =
    "Обсудили первый пункт. ".repeat(275) +
    "Утверждение пока не дано. ".repeat(150);
  const sources = sourceBatches(m.chunks, 6000);
  assert.equal(sources.length, 2);
  const calls = new Map<string, number>();
  let fail = true;
  const queue = new ProcessingQueue(
    store,
    {
      transcribe: async () => {
        throw new Error("Existing transcript must not be reprocessed");
      },
      brief: async (input) => {
        calls.set(input, (calls.get(input) ?? 0) + 1);
        if (input === sources[1] && fail) {
          fail = false;
          throw new Error("Fixture interrupted summary");
        }
        const quote = input.includes("Утверждение пока не дано.")
          ? "Утверждение пока не дано."
          : "Обсудили первый пункт.";
        return {
          overview: "Обсудили вопрос.",
          topics: [
            {
              title: "Вопрос",
              text: quote,
              evidence: [{ source: m.chunks[0]!.id, quote }],
            },
          ],
          decisions: [],
          actions: [],
          questions: [],
        };
      },
    },
    () => true,
    () => {},
  );
  t.after(() => queue.shutdown());
  queue.resume(m.id);
  await eventually(() => m.status === "error");
  assert.equal(calls.get(sources[0]!), 1);
  queue.resume(m.id);
  await eventually(() => m.status === "ready");
  assert.equal(calls.get(sources[0]!), 1);
  assert.equal(calls.get(sources[1]!), 2);
  assert.equal(m.summaryModelUsed, "Qwen3-4B-Q4_K_M");
});

test("cancelling cached summary before completion preserves the previous visible brief", async (t) => {
  const store = library(t),
    m = captured(store);
  m.chunks[0]!.text = speech;
  const queue = new ProcessingQueue(
    store,
    {
      transcribe: async () => speech,
      brief: async (_input, meeting) => brief(meeting),
    },
    () => true,
    () => {},
  );
  t.after(() => queue.shutdown());
  queue.resume(m.id);
  await eventually(() => m.status === "ready");
  const previous = { ...brief(m), overview: "Предыдущая версия резюме." };
  m.brief = previous;
  queue.resume(m.id);
  queue.pause(m.id);
  await eventually(() => !queue.busy(m.id));
  assert.equal(m.status, "paused");
  assert.deepEqual(m.brief, previous);
});
