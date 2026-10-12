#!/usr/bin/env python3
"""Fetch immutable, checksum-verified runtime/model artifacts. No install scripts executed."""
import concurrent.futures
import hashlib
import pathlib
import subprocess
import tarfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
ASSETS = [
    ("models/ggml-silero-v6.2.0.bin", "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin", "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"),
    ("models/ggml-small-q5_1.bin", "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin", "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"),
    ("models/Qwen3-4B-Q4_K_M.gguf", "https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/bc640142c66e1fdd12af0bd68f40445458f3869b/Qwen3-4B-Q4_K_M.gguf", "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5"),
    ("vendor/llama.tar.gz", "https://github.com/ggml-org/llama.cpp/releases/download/b10844/llama-b10844-bin-macos-arm64.tar.gz", "a78aa1cd593339bfacfd45d2f9ca87ec83b87651f93a32ccbed4acd3eb4a90f5"),
]

def sha(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()

def fetch(asset):
    name, url, digest = asset
    target = ROOT / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and sha(target) == digest:
        print(f"Verified {name}", flush=True)
        return
    partial = target.with_suffix(target.suffix + ".partial")
    subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "30", "--max-time", "3600", "--continue-at", "-", "--silent", "--show-error", "--output", str(partial), url], check=True)
    if sha(partial) != digest:
        partial.unlink()
        raise RuntimeError(f"Checksum mismatch: {name}")
    partial.replace(target)
    print(f"Downloaded and verified {name}", flush=True)

if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(fetch, ASSETS))
    with tarfile.open(ROOT / "vendor/llama.tar.gz") as archive:
        archive.extractall(ROOT / "vendor/llama", filter="data")
