#!/bin/bash
# Builds build/Longarm.app. Pass --run to (re)launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Longarm.app
# Update the bundle in place rather than deleting it: a fresh bundle on every build leaves Spotlight
# showing one "Longarm" per old build.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
rm -f "$APP/Contents/MacOS/Longarm"
cp Info.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # redraw with: swift icon/make-icon.swift

swiftc -O -swift-version 5 -target arm64-apple-macos15 \
    -framework AppKit -framework Network -framework CoreImage -framework ScreenCaptureKit \
    -framework VideoToolbox -framework CoreMedia -framework IOKit \
    Sources/*.swift -o "$APP/Contents/MacOS/Longarm"

# A stable signing identity keeps the Accessibility and Screen Recording grants across rebuilds.
# Override with LONGARM_SIGN_IDENTITY; falls back to ad-hoc (permissions reset on each build).
IDENTITY="${LONGARM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--run" ]]; then
    # Let it exit before relaunching (it first stops any screen capture, up to 1 s).
    if pkill -x Longarm; then
        for _ in 1 2 3 4 5 6; do pgrep -x Longarm >/dev/null || break; sleep 0.5; done
    fi
    open "$APP"
fi
