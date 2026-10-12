import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

test("PCM worklet keeps speech from the right channel while output monitoring stays silent", () => {
  type Processor = {
    process(inputs: Float32Array[][], outputs: Float32Array[][]): boolean;
    port: { onmessage: (event: { data: string }) => void };
  };
  let Constructor: new () => Processor;
  const messages: { pcm?: ArrayBuffer; flushed?: boolean }[] = [];
  const source = fs.readFileSync(
    new URL("../src/renderer/pcm-worklet.js", import.meta.url),
    "utf8",
  );
  vm.runInNewContext(source, {
    AudioWorkletProcessor: class {
      port = {
        onmessage: null,
        postMessage: (message: (typeof messages)[number]) =>
          messages.push(message),
      };
    },
    registerProcessor: (_name: string, value: typeof Constructor) => {
      Constructor = value;
    },
  });
  const processor = new Constructor!();
  const left = new Float32Array(128);
  const right = new Float32Array(128).fill(0.5);
  const output = [new Float32Array(128).fill(1), new Float32Array(128).fill(1)];
  processor.process([[left, right]], [output]);
  processor.port.onmessage({ data: "pause" });
  assert.equal(messages.length, 2);
  const pcm = new Int16Array(messages[0]!.pcm!);
  assert.equal(pcm.length, 128);
  assert.ok(pcm.every((sample) => sample === 8192));
  assert.ok(output.every((channel) => channel.every((sample) => sample === 0)));
  processor.process([[left, right]], [output]);
  processor.port.onmessage({ data: "stop" });
  assert.equal(messages.filter((message) => message.pcm).length, 1);
});
