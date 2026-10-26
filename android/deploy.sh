#!/bin/bash
# Builds the debug APK and installs it straight onto the phone over adb (USB or Wireless debugging),
# then opens the app. Pairing and settings are kept.
set -euo pipefail
cd "$(dirname "$0")"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"

./gradlew assembleDebug -q
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n dev.longarm/.MainActivity >/dev/null
echo "Installed $(grep -o 'versionName = "[^"]*"' app/build.gradle.kts | cut -d'"' -f2) and opened Longarm."
