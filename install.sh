#!/bin/bash
# Now Playing Island – build & install
# Usage: ./install.sh
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="NowPlayingIsland"
APP="$HOME/Applications/$APP_NAME.app"
LABEL="io.github.nowplayingisland"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
BUILD="$ROOT/build"

say()  { printf '\033[1m→ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# --- Checks ------------------------------------------------------------------
[ "$(uname)" = "Darwin" ] || fail "Now Playing Island only runs on macOS."

say "Checking requirements..."
command -v swiftc >/dev/null 2>&1 \
    || fail "Swift compiler not found. Install the Command Line Tools with: xcode-select --install"
command -v brew >/dev/null 2>&1 \
    || fail "Homebrew not found. Install it from https://brew.sh and run this script again."
if ! command -v media-control >/dev/null 2>&1; then
    say "Installing media-control..."
    brew install media-control
fi

# --- Build -------------------------------------------------------------------
say "Building (this can take a minute)..."
rm -rf "$BUILD"
mkdir -p "$BUILD"
swiftc -swift-version 5 -O -parse-as-library \
    -o "$BUILD/$APP_NAME" "$ROOT/Sources/main.swift"

# --- Install -----------------------------------------------------------------
say "Installing to $APP ..."
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Clean up the launch agent used by pre-release builds
rm -f "$HOME/Library/LaunchAgents/local.nowplayingisland.plist"

say "Enabling launch at login..."
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

open "$APP"
printf '\033[32m✓ Done!\033[0m If macOS asks for access to system audio, click Allow.\n'
