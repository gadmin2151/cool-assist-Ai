#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=306c88f4d1286aec1bf96e544632897886af5501
if [ ! -d vendor/whisper.cpp/.git ]; then
  mkdir -p vendor
  git clone --depth 1 --branch v1.9.2 https://github.com/ggml-org/whisper.cpp.git vendor/whisper.cpp
fi
actual=$(git -C vendor/whisper.cpp rev-parse HEAD)
if [ "$actual" != "$revision" ]; then
  echo 'Unexpected whisper.cpp revision; refusing to change an existing checkout.' >&2
  exit 1
fi
cmake_bin=${CMAKE_BIN:-cmake}
if [ "$cmake_bin" = cmake ] && [ -x .tools/bin/cmake ]; then cmake_bin="$PWD/.tools/bin/cmake"; fi
"$cmake_bin" -S vendor/whisper.cpp -B vendor/whisper.cpp/build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
"$cmake_bin" --build vendor/whisper.cpp/build --target whisper-cli -j "${BUILD_JOBS:-4}"
bash scripts/build-speech-worker.sh
