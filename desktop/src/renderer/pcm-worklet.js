class PCMRecorder extends AudioWorkletProcessor {
  constructor() {
    super();
    this.samples = new Int16Array(4096);
    this.offset = 0;
    this.paused = false;
    this.port.onmessage = (event) => {
      if (event.data === "pause" || event.data === "stop") {
        this.flush();
        this.paused = true;
        this.port.postMessage({ flushed: true });
      }
      if (event.data === "resume") this.paused = false;
    };
  }
  flush() {
    if (this.offset) {
      const output = this.samples.slice(0, this.offset);
      this.port.postMessage({ pcm: output.buffer }, [output.buffer]);
      this.offset = 0;
    }
  }
  process(inputs, outputs) {
    const channels = inputs[0];
    const frames = channels?.[0]?.length ?? 0;
    // Keep the audio graph alive without feeding microphone sound to speakers.
    for (const output of outputs[0] ?? []) output.fill(0);
    if (channels?.length && !this.paused)
      for (let frame = 0; frame < frames; frame++) {
        // Loopback and external interfaces may put speech only in the right channel.
        let sample = 0;
        for (const channel of channels) sample += channel[frame] ?? 0;
        sample /= channels.length;
        this.samples[this.offset++] = Math.round(
          Math.max(-1, Math.min(1, sample)) * 32767,
        );
        if (this.offset === 4096) this.flush();
      }
    return true;
  }
}
registerProcessor("pcm-recorder", PCMRecorder);
