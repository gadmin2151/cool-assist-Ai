export const SAMPLE_RATE = 16000;
export const MAX_SAMPLES = SAMPLE_RATE * 22;
export const MIN_SAMPLES = SAMPLE_RATE * 7;
export function pcmStats(pcm: Buffer): { rms: number; peak: number } {
  if (pcm.length % 2) throw new Error("Неполный PCM-буфер.");
  let energy = 0;
  let peak = 0;
  for (let i = 0; i < pcm.length; i += 2) {
    const v = pcm.readInt16LE(i) / 32768;
    energy += v * v;
    peak = Math.max(peak, Math.abs(v));
  }
  return { rms: pcm.length ? Math.sqrt(energy / (pcm.length / 2)) : 0, peak };
}
export function wav(pcm: Buffer): Buffer {
  if (pcm.length % 2 || pcm.length > MAX_SAMPLES * 2)
    throw new Error("Некорректный размер фрагмента.");
  const header = Buffer.alloc(44);
  header.write("RIFF");
  header.writeUInt32LE(pcm.length + 36, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(SAMPLE_RATE, 24);
  header.writeUInt32LE(SAMPLE_RATE * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}
export function timestamp(seconds: number): string {
  const s = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  return [Math.floor(s / 3600), Math.floor(s / 60) % 60, s % 60]
    .map((x) => String(x).padStart(2, "0"))
    .join(":");
}
