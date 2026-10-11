#!/bin/bash
# Builds the patched Reddit IPA into packages/.
# Usage: scripts/build-ipa.sh path/to/Decrypted-Reddit.ipa [debug]
#   debug: include the RedditFilter debug menu and login diagnostics (LoginDebug.x)
set -euo pipefail
cd "$(dirname "$0")/.."

ipa="${1:?usage: scripts/build-ipa.sh path/to/Reddit.ipa [debug]}"
ipa="$(cd "$(dirname "$ipa")" && pwd)/$(basename "$ipa")"
export THEOS="${THEOS:-$HOME/theos}"

version=$(unzip -p "$ipa" 'Payload/*.app/Info.plist' | plutil -extract CFBundleShortVersionString raw -)
debug=0
[ "${2:-}" = "debug" ] && debug=1

make clean package SIDELOADED=1 FINALPACKAGE=1 DEBUG_MENU=$debug IPA="$ipa" APP_VERSION="$version"
