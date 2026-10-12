#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product MeetSecretar
TEST_BIN_DIR=$(swift build --show-bin-path)
xcrun swiftc -parse-as-library -swift-version 5 -I "$TEST_BIN_DIR/Modules" \
  Sources/MeetSecretar/AppModel.swift Sources/MeetSecretar/CaptureService.swift \
  Sources/MeetSecretar/CaptureAccess.swift Sources/MeetSecretar/Recording.swift Sources/MeetSecretar/APIKeyStore.swift \
  Tests/MeetingAppChecks/AppModelChecks.swift "$TEST_BIN_DIR/MeetingCore.build/"*.o \
  -o "$TEST_BIN_DIR/MeetingAppChecks"
"$TEST_BIN_DIR/MeetingAppChecks"
