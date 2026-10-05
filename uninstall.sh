#!/bin/bash
# Now Playing Island – uninstall
# Usage: ./uninstall.sh
set -euo pipefail

APP="$HOME/Applications/NowPlayingIsland.app"

pkill -x NowPlayingIsland >/dev/null 2>&1 || true
rm -rf "$APP"
rm -f "$HOME/Library/LaunchAgents/io.github.nowplayingisland.plist"
rm -f "$HOME/Library/LaunchAgents/local.nowplayingisland.plist"

printf '\033[32m✓ Now Playing Island removed.\033[0m\n'
echo "media-control was left installed. Remove it with: brew uninstall media-control"
echo "You can also revoke audio access in System Settings → Privacy & Security."
