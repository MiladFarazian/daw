#!/usr/bin/env bash
# Build, launch Gosan with a demo project opened to a given screen, and capture its
# window(s) to PNG via ScreenCaptureKit — so the UI can be inspected/iterated headlessly.
#
#   tools/ui-shot.sh <screen> <out.png>
#   <screen>: main | pianoroll | stepseq | chords | automation | mixer | loops | generate
set -euo pipefail
SCREEN="${1:-main}"
OUT="${2:-/tmp/gosan-ui.png}"
APP="./build/Build/Products/Debug/Gosan.app"

[ -d "$APP" ] || xcodebuild -project Gosan.xcodeproj -scheme Gosan -configuration Debug \
    -derivedDataPath ./build -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build \
    >/dev/null 2>&1
swiftc tools/capture-window.swift -o ./build/capwin 2>/dev/null || true

GOSAN_DEMO=1 GOSAN_OPEN="$SCREEN" open -n "$APP"
sleep 5
PID=$(pgrep -n Gosan)
./build/capwin "$PID" "$OUT"
kill "$PID" 2>/dev/null || true
