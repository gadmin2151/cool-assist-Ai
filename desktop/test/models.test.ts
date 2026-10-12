import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";
import {
  LocalModels,
  runtimeExecutable,
  type ModelAsset,
} from "../src/core/models";

async function settled(models: LocalModels): Promise<void> {
  for (let i = 0; i < 200; i++) {
    const s = models.state();
    if (!s.checking && !s.downloading) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error("Model state did not settle");
}
function fixture(content = "synthetic model fixture"): {
  asset: ModelAsset;
  bytes: Buffer;
} {
  const bytes = Buffer.from(content);
  return {
    bytes,
    asset: {
      name: "fixture-model.bin",
      label: "Fixture",
      bytes: bytes.length,
      sha256: createHash("sha256").update(bytes).digest("hex"),
      url: "https://example.invalid/pinned/model",
    },
  };
}
function directory(t: import("node:test").TestContext): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), "cool-model-check-"));
  t.after(() => fs.rmSync(d, { recursive: true, force: true }));
  return d;
}
test("local model setup is opt-in and resumes only a verified matching byte range", async (t) => {
  const root = directory(t);
  const { asset, bytes } = fixture();
  fs.writeFileSync(
    path.join(root, asset.name + ".partial"),
    bytes.subarray(0, 8),
  );
  let calls = 0;
  const models = new LocalModels(
    root,
    () => {},
    [asset],
    async (_url, init) => {
      calls++;
      assert.equal(new Headers(init?.headers).get("range"), "bytes=8-");
      return new Response(new Uint8Array(bytes.subarray(8)), {
        status: 206,
        headers: {
          "content-range": `bytes 8-${bytes.length - 1}/${bytes.length}`,
        },
      });
    },
  );
  await settled(models);
  assert.equal(calls, 0);
  assert.equal(models.state().ready, false);
  models.start();
  await settled(models);
  assert.equal(calls, 1);
  assert.equal(models.state().ready, true);
  assert.deepEqual(fs.readFileSync(path.join(root, asset.name)), bytes);
});
test("model checksum failure never enables inference and is retryable", async (t) => {
  const root = directory(t);
  const { asset, bytes } = fixture();
  let valid = false;
  const models = new LocalModels(
    root,
    () => {},
    [asset],
    async () =>
      new Response(new Uint8Array(valid ? bytes : Buffer.alloc(bytes.length))),
  );
  await settled(models);
  models.start();
  await settled(models);
  assert.equal(models.state().ready, false);
  assert.ok(models.state().error);
  assert.equal(fs.existsSync(path.join(root, asset.name)), false);
  valid = true;
  models.start();
  await settled(models);
  assert.equal(models.state().ready, true);
});
test("restart verifies existing models without a network request", async (t) => {
  const root = directory(t);
  const { asset, bytes } = fixture();
  fs.writeFileSync(path.join(root, asset.name), bytes);
  const models = new LocalModels(
    root,
    () => {},
    [asset],
    async () => {
      throw new Error("No network allowed");
    },
  );
  await settled(models);
  assert.equal(models.state().ready, true);
});
test("runtime resolution stays inside the packaged tree and rejects absent executables", (t) => {
  const root = directory(t);
  fs.mkdirSync(path.join(root, "runtime"));
  fs.writeFileSync(path.join(root, "runtime", "whisper-cli"), "fixture");
  assert.equal(
    runtimeExecutable(root, "whisper-cli"),
    path.join(root, "runtime", "whisper-cli"),
  );
  assert.throws(() => runtimeExecutable(root, "absent-executable"));
});
