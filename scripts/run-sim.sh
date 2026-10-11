#!/bin/bash
# Builds a debug IPA, converts it for the simulator, installs it on the booted
# simulator and launches it. App data (login) survives the reinstall.
#
# Usage: scripts/run-sim.sh path/to/Reddit-Decrypted.ipa
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-ipa.sh "$1" debug
scripts/make-sim-app.sh
# The bundle ID is unchanged in the simulator, so the sideload fix is not needed.
rm -f build/sim/RedditApp.app/Frameworks/RedditSideloadFix.dylib
codesign -f -s - build/sim/RedditApp.app

xcrun simctl terminate booted com.reddit.Reddit 2>/dev/null || true
xcrun simctl install booted build/sim/RedditApp.app
xcrun simctl launch booted com.reddit.Reddit
