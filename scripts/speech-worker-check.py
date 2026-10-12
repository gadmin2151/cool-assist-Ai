#!/usr/bin/env python3
"""Offline ASR regression check using whisper.cpp's public JFK sample and synthetic silence.

Does not read meeting folders, use a microphone, call an API, or download models.
Build the resident helper first with scripts/build-speech-worker.sh.
"""
import argparse
import array
import json
import pathlib
import re
import subprocess
import tempfile
import time
import wave

ROOT = pathlib.Path(__file__).resolve().parents[1]
REFERENCE = (
    "And so my fellow Americans ask not what your country can do for you "
    "ask what you can do for your country"
)


def tokens(text):
    return re.findall(r"[a-z]+", text.lower())


def word_error_rate(expected, actual):
    reference, candidate = tokens(expected), tokens(actual)
    previous = list(range(len(candidate) + 1))
    for index, word in enumerate(reference):
        row = [index + 1]
        for position, other in enumerate(candidate):
            row.append(min(row[-1] + 1, previous[position + 1] + 1,
                           previous[position] + (word != other)))
        previous = row
    return previous[-1] / len(reference)


def check(worker):
    paths = [worker, ROOT / "models/ggml-small-q5_1.bin",
             ROOT / "models/ggml-silero-v6.2.0.bin"]
    for path in paths:
        if not path.is_file():
            raise RuntimeError(f"Missing required local artifact: {path.name}")
    with wave.open(str(ROOT / "vendor/whisper.cpp/samples/jfk.wav"), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
            raise RuntimeError("Fixture must be mono PCM16 at 16 kHz")
        original = array.array("h", audio.readframes(audio.getnframes()))
    variants = {
        "clear": original,
        "quiet": array.array("h", (round(value * 0.035) for value in original)),
        "silence": array.array("h", [0] * 16000 * 8),
    }
    with tempfile.TemporaryDirectory(prefix="CoolAssistAi-SpeechCheck-") as temporary:
        folder = pathlib.Path(temporary)
        for name, samples in variants.items():
            with wave.open(str(folder / f"{name}.wav"), "wb") as audio:
                audio.setnchannels(1)
                audio.setsampwidth(2)
                audio.setframerate(16000)
                audio.writeframes(samples.tobytes())
        process = subprocess.Popen([str(path) for path in paths], stdin=subprocess.PIPE,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            # The repeated clear run distinguishes first-load time from resident inference.
            for index, name in enumerate(["clear", "clear", "quiet", "silence"]):
                output = folder / f"result-{index}.json"
                request = {"audio": str(folder / f"{name}.wav"), "output": str(output),
                           "language": "en"}
                started = time.monotonic()
                process.stdin.write((json.dumps(request) + "\n").encode())
                process.stdin.flush()
                while not output.exists():
                    if process.poll() is not None:
                        raise RuntimeError("Native worker stopped before returning a result")
                    if time.monotonic() - started > 180:
                        raise RuntimeError("ASR fixture exceeded the 180 second timeout")
                    time.sleep(0.05)
                result = json.loads(output.read_text())
                if "error" in result:
                    raise RuntimeError("Native worker rejected the fixture")
                recognized = " ".join(item["text"].strip() for item in result["transcription"])
                score = word_error_rate(REFERENCE, recognized) if name != "silence" else None
                if name == "silence" and recognized:
                    raise RuntimeError("Silence produced a spurious transcript")
                if score is not None and (score > 0.1 or "ask not" not in " ".join(tokens(recognized))):
                    raise RuntimeError(f"{name}: excessive word errors or missing negation (WER={score:.3f})")
                print(json.dumps({"fixture": name, "pass": True, "word_error_rate": score,
                                  "seconds": round(time.monotonic() - started, 3),
                                  "segments": len(result["transcription"])}), flush=True)
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=pathlib.Path,
                        default=ROOT / "vendor/whisper.cpp/build/bin/meet-transcriber")
    options = parser.parse_args()
    check(options.worker.resolve())


if __name__ == "__main__":
    main()
