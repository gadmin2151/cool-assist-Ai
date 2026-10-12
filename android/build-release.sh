#!/bin/bash
set -euo pipefail

android_root="$(cd "$(dirname "$0")" && pwd)"
project_root="$(dirname "$android_root")"
android_tools="$project_root/.tools/android"

if [[ -z "${JAVA_HOME:-}" && -d "$android_tools/jdk-17.0.20.1+1/Contents/Home" ]]; then
  export JAVA_HOME="$android_tools/jdk-17.0.20.1+1/Contents/Home"
fi
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$android_tools/gradle-user-home}"
android_keystore="${MEET_ANDROID_SIGNING_DIR:-$android_tools/signing}"
android_output="$project_root/dist/android"
signing_service='cc.idomus.meetprotocol.android.release-signing'
signing_account='meet-protocol-build'
umask 077
mkdir -p "$android_keystore" "$android_output"

if [[ ! -f "$android_keystore/release.jks" ]]; then
  if /usr/bin/security find-generic-password -s "$signing_service" -a "$signing_account" >/dev/null 2>&1; then
    echo 'Signing identity exists in Keychain but the keystore is missing. Restore the original keystore before building updates.' >&2
    exit 1
  fi
  export MEET_SIGNING_PASSWORD="$(/usr/bin/openssl rand -base64 36)"
  /usr/bin/security add-generic-password -s "$signing_service" -a "$signing_account" \
    -w "$MEET_SIGNING_PASSWORD" -T /usr/bin/security
  "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$android_keystore/release.jks" \
    -storepass:env MEET_SIGNING_PASSWORD -keypass:env MEET_SIGNING_PASSWORD \
    -alias meet-protocol -keyalg RSA -keysize 3072 -validity 10000 \
    -dname 'CN=Meet Protocol Personal, O=Meet Protocol' >/dev/null
fi
unset MEET_SIGNING_PASSWORD

cd "$android_root"
./gradlew --no-daemon :app:testDebugUnitTest :app:lintRelease :app:assembleRelease
android_build_tools="$ANDROID_HOME/build-tools/35.0.0"
"$android_build_tools/zipalign" -f -P 16 4 app/build/outputs/apk/release/app-release-unsigned.apk "$android_output/aligned.apk"
if ! MEET_SIGNING_PASSWORD="$(/usr/bin/security find-generic-password -s "$signing_service" -a "$signing_account" -w)"; then
  echo 'Cannot read this app signing identity from Keychain. Restore access before building an update.' >&2
  exit 1
fi
export MEET_SIGNING_PASSWORD
"$android_build_tools/apksigner" sign --ks "$android_keystore/release.jks" --ks-key-alias meet-protocol \
  --ks-pass env:MEET_SIGNING_PASSWORD --key-pass env:MEET_SIGNING_PASSWORD \
  --out "$android_output/CoolAssistAi-Android-2.0.0.apk" "$android_output/aligned.apk"
rm "$android_output/aligned.apk"
unset MEET_SIGNING_PASSWORD
"$android_build_tools/apksigner" verify --verbose --print-certs "$android_output/CoolAssistAi-Android-2.0.0.apk"
cd "$android_output"
shasum -a 256 CoolAssistAi-Android-2.0.0.apk > SHA256SUMS.txt
echo "APK: $android_output/CoolAssistAi-Android-2.0.0.apk"
