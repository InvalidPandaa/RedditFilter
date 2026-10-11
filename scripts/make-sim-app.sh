#!/bin/bash
# Turns the patched device app (output of `make package SIDELOADED=1 ...`) into
# one the iOS Simulator on Apple Silicon will load: every Mach-O gets its
# platform switched from iOS to iOS Simulator and is re-signed ad hoc.
# App extensions are dropped; they are not needed to test the feed or settings.
#
# Usage: scripts/make-sim-app.sh [path/to/RedditApp.app]   -> build/sim/RedditApp.app
set -euo pipefail
cd "$(dirname "$0")/.."

src="${1:-.theos/_/Payload/RedditApp.app}"
[ -d "$src" ] || { echo "error: $src not found (build the IPA first)" >&2; exit 1; }
out="build/sim/$(basename "$src")"

rm -rf build/sim && mkdir -p build/sim
cp -a "$src" "$out"
rm -rf "$out/PlugIns" "$out/Extensions" "$out/Watch" "$out/_CodeSignature" "$out/SC_Info"

sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
count=0
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q 'Mach-O' || continue
  minos=$(vtool -show-build "$file" | awk '$1 == "minos" { print $2; exit }')
  vtool -set-build-version iossim "${minos:-16.0}" "$sdk" -replace -output "$file" "$file" 2>/dev/null
  count=$((count + 1))
done < <(find "$out" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)

# Sign inside out: nested code first, the app bundle last.
find "$out" -depth \( -name '*.dylib' -o -name '*.framework' \) -print0 | xargs -0 codesign -f -s - 2>/dev/null
codesign -f -s - "$out"

echo "converted $count binaries -> $out"
