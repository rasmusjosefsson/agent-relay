#!/usr/bin/env bash
# Builds Slack Relay.app and installs it in /Applications (or $SLACK_RELAY_APP_DIR). Usage: app/scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-release}
id=io.github.rasmusjosefsson.slack-relay
swift build -c "$config"
app="dist/Slack Relay.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp ".build/$config/SlackRelay" "$app/Contents/MacOS/SlackRelay"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Slack Relay</string>
  <key>CFBundleDisplayName</key><string>Slack Relay</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>SlackRelay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# SwiftPM records the deployment target as the SDK version (sdk 14.0), which makes macOS run the
# app in compatibility mode: solid toolbar band, no scroll edge effect. Stamp the real SDK version.
bin="$app/Contents/MacOS/SlackRelay"
minos="$(vtool -show-build "$bin" | awk '/minos/ {print $2; exit}')"
vtool -set-build-version macos "$minos" "$(xcrun --sdk macosx --show-sdk-version)" -replace -output "$bin" "$bin"
codesign --force --sign - "$app" >/dev/null 2>&1 || true

# Replace the installed copy; a running one is quit and reopened on the new build
dest="${SLACK_RELAY_APP_DIR:-/Applications}/Slack Relay.app"
running=false
if pgrep -fq "$dest/Contents/MacOS/SlackRelay"; then
  running=true
  osascript -e "quit app id \"$id\"" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do pgrep -fq "$dest/Contents/MacOS/SlackRelay" || break; sleep 0.25; done
fi
rm -rf "$dest"
ditto "$app" "$dest"
echo "installed $dest"
[[ "$running" == false ]] || open "$dest"
