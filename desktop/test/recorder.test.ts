import test from "node:test";
import assert from "node:assert/strict";
import { Recorder } from "../src/renderer/recorder";

test("rapid pause, resume and stop operations serialize without losing the stop", async () => {
  const calls: string[] = [];
  Object.assign(globalThis, {
    window: {
      cool: {
        pauseCapture: async (_id: string, paused: boolean) => {
          calls.push(paused ? "pause" : "resume");
        },
        stop: async () => {
          calls.push("stop");
        },
      },
    },
  });
  const recorder = new Recorder("fixture", (message) => {
    throw new Error(message);
  });
  const context = {
    state: "running",
    suspend: async () => {
      context.state = "suspended";
    },
    resume: async () => {
      context.state = "running";
    },
    close: async () => {
      context.state = "closed";
    },
  };
  let inFlight = 0,
    maximum = 0;
  const port = {
    postMessage: (message: string) => {
      if (message === "resume") return;
      inFlight++;
      maximum = Math.max(maximum, inFlight);
      setTimeout(() => {
        inFlight--;
        const done = Reflect.get(recorder, "flushDone") as (() => void) | null;
        done?.();
      }, 5);
    },
  };
  Object.assign(recorder, { context, worklet: { port } });
  const pause = recorder.pause();
  const resume = recorder.pause();
  const stop = recorder.stop();
  assert.equal(recorder.stop(), stop);
  await Promise.all([pause, resume, stop]);
  assert.deepEqual(calls, ["pause", "resume", "stop"]);
  assert.equal(maximum, 1);
  assert.equal(context.state, "closed");
});
