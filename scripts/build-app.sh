#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Cool Assist Ai.app"
LOCAL_SIGNING=0
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(python3 scripts/local-signing.py)
    LOCAL_SIGNING=1
elif [ "$SIGN_IDENTITY" != "-" ] && [ -f .tools/macos-signing/certificate.pem ]; then
    LOCAL_CERT_SHA1=$(/usr/bin/openssl x509 -in .tools/macos-signing/certificate.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
    REQUESTED_SHA1=$(printf '%s' "$SIGN_IDENTITY" | tr '[:lower:]' '[:upper:]')
    if [ "$REQUESTED_SHA1" = "$LOCAL_CERT_SHA1" ] || [ "$SIGN_IDENTITY" = "Meet Protocol Personal Code Signing v1" ]; then
        SIGN_IDENTITY="$LOCAL_CERT_SHA1"
        LOCAL_SIGNING=1
    fi
fi
CODE_OPTIONS="runtime"
APP_SIGN_ARGS=()
if [ "$LOCAL_SIGNING" = "1" ]; then
    CODE_OPTIONS="0"
    APP_SIGN_ARGS=(--timestamp=none --requirements "=designated => identifier \"cc.idomus.meet-secretar\" and certificate leaf = H\"$SIGN_IDENTITY\"")
elif [ "$SIGN_IDENTITY" = "-" ]; then
    CODE_OPTIONS="0"
fi
swift build -c release --product MeetSecretar
bash scripts/build-speech-worker.sh
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Runtime/llama" "$APP/Contents/Resources/Models" "$APP/Contents/Resources/Licenses"
cp .build/release/MeetSecretar "$APP/Contents/MacOS/MeetProtocol"
rm -f "$APP/Contents/MacOS/MeetSecretar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp vendor/whisper.cpp/build/bin/whisper-cli "$APP/Contents/Resources/Runtime/whisper-cli"
cp vendor/whisper.cpp/build/bin/meet-transcriber "$APP/Contents/Resources/Runtime/meet-transcriber"
cp vendor/llama/llama-b10844/llama-completion "$APP/Contents/Resources/Runtime/llama/"
# Preserve dylib symlinks so every @rpath dependency resolves inside the bundle.
cp -P vendor/llama/llama-b10844/*.dylib "$APP/Contents/Resources/Runtime/llama/"
for model in models/ggml-silero-v6.2.0.bin models/ggml-small-q5_1.bin models/Qwen3-4B-Q4_K_M.gguf; do
    target="$APP/Contents/Resources/Models/$(basename "$model")"
    if [ ! -f "$target" ] || [ "$model" -nt "$target" ]; then cp -c "$model" "$target"; fi
done
cp vendor/whisper.cpp/LICENSE "$APP/Contents/Resources/Licenses/whisper-MIT.txt"
cp Resources/Licenses/* "$APP/Contents/Resources/Licenses/"
cp README.md "$APP/Contents/Resources/README.md"
swift scripts/make-icon.swift dist/AppIcon.iconset
iconutil -c icns dist/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
while IFS= read -r -d '' library; do codesign --force --sign "$SIGN_IDENTITY" "$library"; done < <(find "$APP/Contents/Resources/Runtime" -type f -name '*.dylib' -print0)
codesign --force --options "$CODE_OPTIONS" --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/Runtime/whisper-cli"
codesign --force --options "$CODE_OPTIONS" --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/Runtime/meet-transcriber"
codesign --force --options "$CODE_OPTIONS" --sign "$SIGN_IDENTITY" "$APP/Contents/Resources/Runtime/llama/llama-completion"
codesign --force --options "$CODE_OPTIONS" --entitlements Resources/MeetSecretar.entitlements --sign "$SIGN_IDENTITY" "${APP_SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
plutil -lint "$APP/Contents/Info.plist"
