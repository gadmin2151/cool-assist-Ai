export class Recorder {
  context: AudioContext | null = null;
  analyser: AnalyserNode | null = null;
  private streams: MediaStream[] = [];
  private worklet: AudioWorkletNode | null = null;
  private pending: Promise<void> = Promise.resolve();
  private buffered = 0;
  private flushDone: (() => void) | null = null;
  private stopped = false;
  private operations: Promise<void> = Promise.resolve();
  private stopOperation: Promise<void> | null = null;
  paused = false;
  samples = 0;
  constructor(
    readonly id: string,
    private failure: (message: string) => void,
  ) {}
  async connect(
    microphone: MediaStream,
    system: MediaStream | null,
  ): Promise<void> {
    this.streams = [microphone, ...(system ? [system] : [])];
    for (const stream of this.streams)
      for (const track of stream.getAudioTracks())
        track.addEventListener("ended", () => {
          if (!this.stopped)
            this.failure("Аудиоустройство отключено. Запись сохранена.");
        });
    this.context = new AudioContext({ sampleRate: 16000 });
    if (this.context.sampleRate !== 16000)
      throw new Error("Не удалось настроить частоту аудио.");
    await this.context.audioWorklet.addModule("./pcm-worklet.js");
    this.analyser = this.context.createAnalyser();
    this.analyser.fftSize = 256;
    this.analyser.smoothingTimeConstant = 0.72;
    const mixer = this.context.createGain();
    mixer.gain.value = system ? 0.65 : 1;
    for (const stream of this.streams)
      this.context
        .createMediaStreamSource(new MediaStream(stream.getAudioTracks()))
        .connect(mixer);
    mixer.connect(this.analyser);
    this.worklet = new AudioWorkletNode(this.context, "pcm-recorder");
    mixer.connect(this.worklet);
    this.worklet.connect(this.context.destination);
    this.worklet.port.onmessage = (event) => {
      if (event.data.flushed) {
        this.flushDone?.();
        this.flushDone = null;
        return;
      }
      const pcm = event.data.pcm as ArrayBuffer;
      if (!(pcm instanceof ArrayBuffer) || this.stopped) return;
      this.samples += pcm.byteLength / 2;
      this.buffered += pcm.byteLength;
      if (this.buffered > 4 * 1024 * 1024) {
        this.failure("Диск не успевает сохранять звук. Запись остановлена.");
        return;
      }
      this.pending = this.pending
        .then(() => window.cool.append(this.id, pcm))
        .catch((error) => {
          this.failure(
            error instanceof Error
              ? error.message
              : "Не удалось сохранить аудио.",
          );
        })
        .finally(() => {
          this.buffered -= pcm.byteLength;
        });
    };
    await this.context.resume();
  }
  private async flush(command: "pause" | "stop"): Promise<void> {
    if (this.worklet && !this.paused) {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => {
          this.flushDone = null;
          reject(new Error("Не удалось завершить текущий аудиобуфер."));
        }, 3000);
        this.flushDone = () => {
          clearTimeout(timer);
          resolve();
        };
        this.worklet!.port.postMessage(command);
      });
    }
    await this.pending;
  }
  pause(): Promise<void> {
    if (this.stopOperation) return this.stopOperation;
    const operation = this.operations.then(
      () => this.togglePause(),
      () => this.togglePause(),
    );
    this.operations = operation.catch(() => {
      /* Keep the operation queue usable after a surfaced failure. */
    });
    return operation;
  }
  private async togglePause(): Promise<void> {
    if (this.paused) {
      await window.cool.pauseCapture(this.id, false);
      await this.context?.resume();
      this.worklet?.port.postMessage("resume");
      this.paused = false;
    } else {
      await this.flush("pause");
      await this.context?.suspend();
      await window.cool.pauseCapture(this.id, true);
      this.paused = true;
    }
  }
  stop(): Promise<void> {
    if (!this.stopOperation) {
      this.stopOperation = this.operations.then(
        () => this.finish(),
        () => this.finish(),
      );
      this.operations = this.stopOperation.catch(() => {
        /* The caller surfaces the failure. */
      });
    }
    return this.stopOperation;
  }
  private async finish(): Promise<void> {
    if (this.stopped) return;
    let failure: unknown;
    try {
      await this.flush("stop");
    } catch (error) {
      failure = error;
    } finally {
      this.stopped = true;
      for (const stream of this.streams)
        for (const track of stream.getTracks()) track.stop();
      try {
        if (this.context && this.context.state !== "closed")
          await this.context.close();
      } finally {
        await this.pending;
        await window.cool.stop(this.id);
      }
    }
    if (failure) throw failure;
  }
}
