#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WHISPER_BUILD="vendor/whisper.cpp/build"
/usr/bin/c++ -O3 -std=c++17 -DNDEBUG -arch arm64 -mmacosx-version-min=15.0 \
  -I vendor/whisper.cpp/include -I vendor/whisper.cpp/ggml/include -isystem vendor/whisper.cpp/examples \
  -Wall -Wextra -Werror Sources/Native/live-asr.cpp \
  "$WHISPER_BUILD/src/libwhisper.a" "$WHISPER_BUILD/ggml/src/libggml.a" \
  "$WHISPER_BUILD/ggml/src/libggml-cpu.a" "$WHISPER_BUILD/ggml/src/ggml-blas/libggml-blas.a" \
  "$WHISPER_BUILD/ggml/src/ggml-metal/libggml-metal.a" "$WHISPER_BUILD/ggml/src/libggml-base.a" \
  -framework Accelerate -framework Foundation -framework Metal -framework MetalKit \
  -o "$WHISPER_BUILD/bin/meet-transcriber"
