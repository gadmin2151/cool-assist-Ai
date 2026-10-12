import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import {
  LocalAIClient,
  localBriefSchema,
  localTranscript,
  runLocalProcess,
  type LocalAIOptions,
} from "../src/core/local-ai";
import { BRIEF_SCHEMA, sourceBatches } from "../src/core/openai";
import { reductionBatches, ProcessingQueue } from "../src/core/queue";
import { wav } from "../src/core/audio";
import {
  append,
  brief,
  captured,
  eventually,
  library,
  pcm,
  preferences,
  speech,
} from "./fixtures";

test("local ASR keeps ordinary phrases and rejects invalid timestamps", () => {
  const segment = (text: string, from = 0, to = 900) => ({
    text,
    offsets: { from, to },
  });
  assert.equal(
    localTranscript(
      {
        transcription: [
          segment("Спасибо за просмотр договора."),
          segment("[BLANK_AUDIO]"),
          segment("вне звука", 1000, 2000),
        ],
      },
      1,
    ),
    "Спасибо за просмотр договора.",
  );
  for (const item of [
    segment("bad", NaN, 900),
    segment("bad", -1, 900),
    segment("bad", 1000, 900),
  ])
    assert.throws(() => localTranscript({ transcription: [item] }, 1));
  assert.equal(localTranscript({ transcription: [] }, 1), "");
});

test("local grammar requires evidence and restricts source IDs before generation", (t) => {
  const store = library(t),
    m = captured(store);
  m.chunks[0]!.text = speech;
  const schema = localBriefSchema(m, sourceBatches(m.chunks)[0]!);
  for (const key of ["topics", "decisions", "actions", "questions"] as const) {
    const evidence = schema.properties[key].items.properties.evidence;
    assert.equal(Reflect.get(evidence, "minItems"), 1);
    const options = Reflect.get(evidence.items, "anyOf") as {
      properties: { source: { const: string }; quote: { enum: string[] } };
    }[];
    assert.equal(options[0]!.properties.source.const, m.chunks[0]!.id);
    assert.ok(
      options[0]!.properties.quote.enum.includes(
        "Бюджет 50 тысяч пока не утверждён.",
      ),
    );
    assert.ok(
      options[0]!.properties.quote.enum.every((quote) =>
        speech.includes(quote),
      ),
    );
  }
  assert.equal(
    Reflect.get(
      BRIEF_SCHEMA.properties.topics.items.properties.evidence,
      "minItems",
    ),
    undefined,
  );
  assert.throws(
    () => localBriefSchema(m, "Текст без ID исходной реплики."),
    /источников/,
  );
});

test("local quote grammar preserves source pairing and excludes quotations outside a reduction batch", (t) => {
  const store = library(t),
    m = captured(store),
    other = captured(store).chunks[0]!;
  m.chunks[0]!.text = "Стоимость пока не согласовали. Анна подготовит расчёт.";
  other.text = "Договор уже подписали.";
  m.chunks.push(other);
  const visibleQuote = "Анна подготовит расчёт.";
  const input = JSON.stringify([
    { source: m.chunks[0]!.id, quote: visibleQuote },
    { source: other.id, quote: other.text },
  ]);
  const schema = localBriefSchema(m, input);
  const options = Reflect.get(
    schema.properties.topics.items.properties.evidence.items,
    "anyOf",
  ) as {
    properties: { source: { const: string }; quote: { enum: string[] } };
  }[];
  assert.deepEqual(
    options.map(({ properties }) => [
      properties.source.const,
      properties.quote.enum,
    ]),
    [
      [m.chunks[0]!.id, [visibleQuote]],
      [other.id, [other.text]],
    ],
  );
});

test("local providers enforce schema, exact citations, private temp cleanup and real CLI contracts", async (t) => {
  const store = library(t),
    m = captured(store);
  m.chunks[0]!.text = speech;
  const runtime = path.join(store.root, "fixture-runtime");
  fs.writeFileSync(runtime, "fixture");
  const options: LocalAIOptions = {
    whisperExecutable: runtime,
    llamaExecutable: runtime,
    whisperModel: runtime,
    summaryModel: runtime,
    vadModel: runtime,
    temporaryRoot: path.join(store.root, "temp"),
  };
  let count = 0;
  const client = new LocalAIClient(
    () => options,
    async (request) => {
      count++;
      assert.equal(request.executable, runtime);
      assert.ok(request.maxOutputBytes <= 1024 * 1024);
      if (request.args.includes("-oj")) {
        assert.ok(request.args.includes("--vad"));
        assert.ok(request.args.includes("200"));
        assert.ok(request.args.includes("3"));
        const output = request.args[request.args.indexOf("-of") + 1]!;
        fs.writeFileSync(
          output + ".json",
          JSON.stringify({
            transcription: [{ text: speech, offsets: { from: 0, to: 1000 } }],
          }),
        );
        return Buffer.alloc(0);
      }
      assert.ok(request.args.includes("--json-schema-file"));
      const schema = JSON.parse(
        fs.readFileSync(
          request.args[request.args.indexOf("--json-schema-file") + 1]!,
          "utf8",
        ),
      );
      assert.equal(
        schema.properties.topics.items.properties.evidence.minItems,
        1,
      );
      assert.ok(request.args.includes("--no-conversation"));
      const prompt = fs.readFileSync(
        request.args[request.args.indexOf("-f") + 1]!,
        "utf8",
      );
      assert.ok(prompt.includes("<think>\n\n</think>"));
      assert.ok(!request.args.some((arg) => arg.includes(speech)));
      return Buffer.from(JSON.stringify(brief(m)) + "\n[end of text]");
    },
  );
  assert.equal(
    await client.transcribe(
      wav(pcm(1)),
      preferences,
      "Do not leak old speech",
      new AbortController().signal,
    ),
    speech,
  );
  assert.deepEqual(
    await client.brief(
      sourceBatches(m.chunks, 6000)[0]!,
      m,
      new AbortController().signal,
    ),
    brief(m),
  );
  assert.equal(count, 2);
  assert.deepEqual(fs.readdirSync(options.temporaryRoot), []);
  await assert.rejects(
    client.brief("x".repeat(6001), m, new AbortController().signal),
    /контекст/,
  );
  const failing = new LocalAIClient(options, async () => {
    throw new Error("Fixture cancellation");
  });
  await assert.rejects(
    failing.transcribe(
      wav(pcm(1)),
      preferences,
      "",
      new AbortController().signal,
    ),
  );
  assert.deepEqual(fs.readdirSync(options.temporaryRoot), []);
});

test("local subprocess handles literal arguments, cancellation and bounded stdout", async (t) => {
  const store = library(t),
    script = path.join(store.root, "worker.cjs");
  fs.writeFileSync(
    script,
    "if(process.argv[2]==='wait'){console.log('ready');setInterval(()=>{},1000)}else if(process.argv[2]==='large'){console.log('x'.repeat(4096))}else{console.log(process.argv[2])}",
  );
  const base = {
    executable: process.execPath,
    cwd: store.root,
    timeoutMs: 5000,
    maxOutputBytes: 1024,
  };
  const literal = "$(touch should-not-exist); & fixture";
  assert.equal(
    (
      await runLocalProcess({
        ...base,
        args: [script, literal],
        signal: new AbortController().signal,
      })
    )
      .toString()
      .trim(),
    literal,
  );
  assert.equal(fs.existsSync(path.join(store.root, "should-not-exist")), false);
  await assert.rejects(
    runLocalProcess({
      ...base,
      args: [script, "large"],
      signal: new AbortController().signal,
    }),
    /размер/,
  );
  const controller = new AbortController();
  const running = runLocalProcess({
    ...base,
    args: [script, "wait"],
    signal: controller.signal,
  });
  setTimeout(() => controller.abort(), 100);
  await assert.rejects(
    running,
    (error) => error instanceof Error && error.name === "AbortError",
  );
});

test("all reduction levels remain in the local context budget and retain final source evidence", (t) => {
  const store = library(t),
    m = captured(store);
  m.chunks[0]!.text = speech;
  const partial = brief(m);
  partial.topics[0]!.text =
    "Длинное точное изложение 🧠. ".repeat(180) + "Последний факт.";
  const batches = reductionBatches([partial, partial, partial], 6000);
  assert.ok(batches.length > 1);
  assert.ok(batches.every((input) => input.length <= 6000));
  assert.ok(batches.some((input) => input.includes("Последний факт.")));
  assert.ok(batches.every((input) => input.includes(m.chunks[0]!.id)));
});

test("local queue needs no cloud consent and allows only one LLM alongside live ASR", async (t) => {
  const store = library(t),
    one = captured(store),
    two = captured(store);
  for (const m of [one, two]) {
    m.settings.provider = "local";
    m.settings.cloudConsent = false;
    m.chunks[0]!.text = speech;
  }
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
  queue.resume(one.id);
  await eventually(() => summaries === 1);
  assert.equal(queue.busy(two.id), false);
  const live = store.create(
    { title: "Local live", project: "", systemAudio: false },
    { ...preferences, provider: "local", cloudConsent: false },
  );
  append(store, live, pcm(22));
  queue.resume(live.id);
  await eventually(() => transcriptions === 1);
  assert.equal(summaries, 1);
  queue.revokeConsent();
  assert.equal(queue.busy(one.id), true);
  assert.equal(live.status, "recording");
  await queue.shutdown();
});
