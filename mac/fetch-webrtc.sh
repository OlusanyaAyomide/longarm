#!/usr/bin/env bash
# Downloads the WebRTC framework the Mac app links (Google's WebRTC, as built and published by
# LiveKit) into vendor/, checked against the checksum LiveKit publishes. build.sh runs it when
# the framework is missing or a different version.
set -euo pipefail

version=150.7871.03
sha256=5727a03c32ed902da570b699e3983e3fb4bfe853ab4da045af70912a7db44557
url="https://github.com/livekit/webrtc-xcframework/releases/download/$version/LiveKitWebRTC.xcframework.zip"

dir="$(cd "$(dirname "$0")" && pwd)/vendor"
if [ -d "$dir/LiveKitWebRTC.xcframework" ] && [ "$(cat "$dir/version" 2>/dev/null)" = "$version" ]; then exit 0; fi

echo "Fetching WebRTC $version (about 70 MB)…"
rm -rf "$dir"
mkdir -p "$dir"
curl -fsSL -o "$dir/webrtc.zip" "$url"
echo "$sha256  $dir/webrtc.zip" | shasum -a 256 -c - >/dev/null || { echo "WebRTC download doesn't match its checksum" >&2; rm -rf "$dir"; exit 1; }
(cd "$dir" && unzip -q webrtc.zip && rm webrtc.zip)
echo "$version" > "$dir/version"
