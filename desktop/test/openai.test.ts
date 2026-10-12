import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import {
  APIError,
  OpenAIClient,
  sourceBatches,
  validateBrief,
  validateInputEvidence,
} from "../src/core/openai";
import { markdown } from "../src/core/markdown";
import { brief, captured, library, preferences, speech } from "./fixtures";

test("evidence must identify a real source and nonempty continuous original quote", (t) => {
  const store = library(t),
    m = captured(store);
  m.chunks[0]!.text = speech;
  const valid = brief(m);
  assert.deepEqual(validateBrief(valid, m.chunks), valid);
  for (const evidence of [
    [{ source: m.chunks[0]!.id, quote: "   " }],
    [{ source: randomUUID(), quote: "Бюджет" }],
    [{ source: m.chunks[0]!.id, quote: "Бюджет утверждён" }],
    [],
  ]) {
    assert.throws(
      () =>
        validateBrief(
          { ...valid, topics: [{ ...valid.topics[0], evidence }] },
          m.chunks,
        ),
      APIError,
    );
  }
  assert.throws(() => validateBrief({ ...valid, overview: " " }, m.chunks));
  assert.throws(() =>
    validateBrief(
      { ...valid, topics: [{ ...valid.topics[0], text: " " }] },
      m.chunks,
    ),
  );
  assert.throws(() =>
    validateInputEvidence(
      valid,
      `[${m.chunks[0]!.id}] Только другой фрагмент того же источника.`,
    ),
  );
});

test("bounded source batches preserve Unicode, spaces and the final decision without loss", () => {
  const content =
    "Бюджет 🧠 ещё не утверждён. ".repeat(180) +
    "Последнее решение: экран оставить.";
  const chunk = {
    id: randomUUID(),
    start: 0,
    duration: 22,
    samples: 352000,
    voiced: true,
    text: content,
  };
  const batches = sourceBatches([chunk], 512);
  assert.ok(batches.length > 5);
  assert.ok(batches.every((b) => b.length <= 512));
  const reconstructed = batches
    .map((b) =>
      b
        .split("\n")
        .filter(Boolean)
        .map((line) => line.slice(line.indexOf("] ") + 2))
        .join(""),
    )
    .join("");
  assert.equal(reconstructed, content);
  assert.ok(!batches.some((b) => /[\ud800-\udbff]\n/.test(b)));
  for (const budget of [0, NaN, 511])
    assert.throws(() => sourceBatches([chunk], budget));
});

test("Markdown keeps full negative wording, source timestamps and pending recognition notice", (t) => {
  const store = library(t),
    m = captured(store);
  m.chunks[0]!.text = speech;
  m.brief = brief(m);
  m.brief.topics[0]!.title = "Бюджет\n## Injected";
  m.bookmarks = [0.5];
  m.chunks.push({
    ...m.chunks[0]!,
    id: randomUUID(),
    start: 1,
    text: undefined,
  });
  const output = markdown(m);
  assert.ok(output.includes(speech));
  assert.ok(output.includes("Источник 00:00:00"));
  assert.ok(output.includes("Ещё не распознано фрагментов: 1"));
  assert.ok(!output.includes("\n## Injected"));
});

test("transcription request obeys model language/context contract and errors redact response bodies", async () => {
  const requests: RequestInit[] = [];
  const client = new OpenAIClient(
    () => "fixture-key",
    async (_url, init) => {
      requests.push(init!);
      return Response.json({ text: "Тестовая речь." });
    },
  );
  await client.transcribe(
    Buffer.alloc(44),
    { ...preferences, glossary: "Тестовый проект" },
    "Контекст",
    new AbortController().signal,
  );
  const form = requests[0]!.body as FormData;
  assert.equal(form.get("language"), "ru");
  assert.equal(form.get("prompt"), "Тестовый проект\nКонтекст");
  assert.equal(requests[0]!.redirect, "error");
  assert.equal(form.get("response_format"), "json");
  await client.transcribe(
    Buffer.alloc(44),
    { ...preferences, transcriptionModel: "gpt-4o-transcribe-diarize" },
    "Контекст",
    new AbortController().signal,
  );
  assert.equal((requests[1]!.body as FormData).get("prompt"), null);
  assert.equal(
    (requests[1]!.body as FormData).get("chunking_strategy"),
    "auto",
  );
  const unauthorized = new OpenAIClient(
    () => "fixture-key",
    async () =>
      Response.json({ error: { message: "DO_NOT_LEAK" } }, { status: 401 }),
  );
  await assert.rejects(
    unauthorized.models(new AbortController().signal),
    (error) =>
      error instanceof APIError && !error.message.includes("DO_NOT_LEAK"),
  );
});

test("Responses uses nonstored strict schema output and validates sources after parsing", async (t) => {
  const store = library(t),
    m = captured(store);
  m.chunks[0]!.text = speech;
  let body: Record<string, unknown> | undefined;
  const client = new OpenAIClient(
    () => "fixture-key",
    async (_url, init) => {
      body = JSON.parse(init!.body as string);
      return Response.json({
        status: "completed",
        output: [
          {
            type: "tool_call",
            content: [{ type: "output_text", text: "malicious" }],
          },
          {
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: JSON.stringify(brief(m)) }],
          },
        ],
      });
    },
  );
  assert.deepEqual(
    await client.brief(
      sourceBatches(m.chunks)[0]!,
      m,
      new AbortController().signal,
    ),
    brief(m),
  );
  assert.equal(body!.store, false);
  assert.equal(
    (body!.text as { format: { strict: boolean } }).format.strict,
    true,
  );
  const nullClient = new OpenAIClient(
    () => "fixture-key",
    async () => Response.json(null),
  );
  await assert.rejects(
    nullClient.models(new AbortController().signal),
    APIError,
  );
});

test("quota and cancellation do not retry; transient failure retries once successfully", async () => {
  let calls = 0;
  const quota = new OpenAIClient(
    () => "fixture-key",
    async () => {
      calls++;
      return Response.json(
        { error: { code: "insufficient_quota" } },
        { status: 429 },
      );
    },
  );
  await assert.rejects(quota.models(new AbortController().signal), APIError);
  assert.equal(calls, 1);
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(quota.models(controller.signal));
  assert.equal(calls, 1);
  calls = 0;
  const transient = new OpenAIClient(
    () => "fixture-key",
    async () => {
      calls++;
      return calls === 1
        ? Response.json(
            {},
            { status: 503, headers: { "retry-after": "invalid" } },
          )
        : Response.json({ data: [{ id: "fixture-model" }] });
    },
  );
  assert.deepEqual(await transient.models(new AbortController().signal), [
    "fixture-model",
  ]);
  assert.equal(calls, 2);
});
