import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { MeetingStore, atomicJSON } from "../src/core/store";
import { MAX_SAMPLES, pcmStats, timestamp } from "../src/core/audio";
import { storedMeeting } from "../src/core/validation";
import { append, captured, library, pcm, preferences } from "./fixtures";

test("capture chunks preserve every PCM sample across pause, resume and restart", (t) => {
  const store = library(t);
  const m = store.create(
    { title: "PCM fixture", project: "", systemAudio: false },
    preferences,
  );
  const first = pcm(25.125),
    last = pcm(2.375);
  append(store, m, first);
  store.pause(m.id, true);
  assert.throws(() => store.append(m.id, Buffer.alloc(2)), /не активна/);
  store.pause(m.id, false);
  append(store, m, last);
  store.stop(m.id);
  const joined = Buffer.concat(
    m.chunks.map((c) => store.audio(m.id, c).subarray(44)),
  );
  assert.deepEqual(joined, Buffer.concat([first, last]));
  assert.equal(m.duration, 27.5);
  assert.ok(m.chunks.every((c) => c.samples <= MAX_SAMPLES));
  const restored = new MeetingStore(store.root).get(m.id);
  assert.deepEqual(restored.chunks, m.chunks);
  assert.equal(restored.duration, 27.5);
});

test("very quiet audio is sent to ASR while digital silence is skipped", (t) => {
  const store = library(t);
  const m = store.create(
    { title: "Quiet", project: "", systemAudio: false },
    preferences,
  );
  append(store, m, pcm(1, 35));
  store.pause(m.id, true);
  store.pause(m.id, false);
  append(store, m, pcm(1, 0));
  store.stop(m.id);
  assert.ok(pcmStats(pcm(1, 35)).rms < 0.0015);
  assert.equal(m.chunks[0]!.voiced, true);
  assert.equal(m.chunks[0]!.text, undefined);
  assert.equal(m.chunks[1]!.voiced, false);
  assert.equal(m.chunks[1]!.text, "");
});

test("crash recovery skips already committed journal prefix and keeps uncommitted tail once", (t) => {
  const store = library(t);
  const m = captured(store);
  const committed = store.audio(m.id, m.chunks[0]!).subarray(44);
  const tail = pcm(2.25);
  m.status = "recording";
  store.save(m);
  atomicJSON(path.join(store.directory(m.id), "journal.json"), { start: 0 });
  fs.writeFileSync(
    path.join(store.directory(m.id), "current.pcm"),
    Buffer.concat([committed, tail]),
  );
  const recovered = new MeetingStore(store.root);
  const restored = recovered.get(m.id);
  assert.equal(restored.status, "interrupted");
  assert.equal(restored.duration, 3.25);
  assert.deepEqual(
    Buffer.concat(
      restored.chunks.map((c) => recovered.audio(m.id, c).subarray(44)),
    ),
    Buffer.concat([committed, tail]),
  );
  assert.deepEqual(
    new MeetingStore(store.root).get(m.id).chunks,
    restored.chunks,
  );
  assert.equal(
    fs.statSync(path.join(store.directory(m.id), "current.pcm")).size,
    0,
  );
});

test("recovery bounds damaged metadata and preserves its original bytes", (t) => {
  const store = library(t);
  const m = captured(store);
  const file = path.join(store.directory(m.id), "meeting.json");
  const invalid = JSON.stringify({ ...m, settings: null });
  fs.writeFileSync(file, invalid);
  const restored = new MeetingStore(store.root);
  assert.equal(restored.list()[0]!.status, "error");
  assert.throws(() => restored.get(m.id), /Метаданные повреждены/);
  assert.equal(restored.inspect(m.id).title, "Повреждённая запись");
  assert.equal(restored.isDamaged(m.id), true);
  assert.throws(() => restored.save(restored.inspect(m.id)), /защищены/);
  assert.equal(fs.readFileSync(file, "utf8"), invalid);
  assert.throws(() => store.directory("../../outside"));
  assert.throws(() =>
    storedMeeting({ ...m, chunks: [m.chunks[0], m.chunks[0]] }),
  );
});

test("atomic metadata failure leaves original snapshot and cleans incomplete temporary file", (t) => {
  const store = library(t);
  const file = path.join(store.root, "atomic.json");
  atomicJSON(file, { before: true });
  const sync = t.mock.method(fs, "fsyncSync", () => {
    throw new Error("Fixture disk failure");
  });
  assert.throws(
    () => atomicJSON(file, { after: true }),
    /Fixture disk failure/,
  );
  sync.mock.restore();
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), { before: true });
  assert.deepEqual(fs.readdirSync(store.root), ["atomic.json"]);
});

test("invalid recovery journal is surfaced without discarding audio", (t) => {
  const store = library(t);
  const m = captured(store);
  const pending = path.join(store.directory(m.id), "current.pcm");
  const data = pcm(1);
  fs.writeFileSync(pending, data);
  atomicJSON(path.join(store.directory(m.id), "journal.json"), { start: -1 });
  const restored = new MeetingStore(store.root);
  assert.throws(() => restored.get(m.id));
  assert.deepEqual(fs.readFileSync(pending), data);
  assert.equal(timestamp(Number.NaN), "00:00:00");
  assert.throws(() => pcmStats(Buffer.alloc(1)));
});
