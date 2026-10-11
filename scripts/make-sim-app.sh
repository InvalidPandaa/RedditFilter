#!/bin/bash
# Turns the patched device app (output of `make package SIDELOADED=1 ...`) into
# one the iOS Simulator on Apple Silicon will load: every Mach-O gets its
# platform switched from iOS to iOS Simulator and is re-signed ad hoc.
# Reddit's app extensions are dropped; they are not needed to test the feed or
# settings. The "Open in Reddit" Safari extension is rebuilt for the simulator.
#
# Usage: scripts/make-sim-app.sh [path/to/RedditApp.app]   -> build/sim/RedditApp.app
set -euo pipefail
cd "$(dirname "$0")/.."

src="${1:-.theos/_/Payload/RedditApp.app}"
[ -d "$src" ] || { echo "error: $src not found (build the IPA first)" >&2; exit 1; }
out="build/sim/$(basename "$src")"

rm -rf build/sim && mkdir -p build/sim
# Keep the app's own entitlements: without an application-identifier the
# simulator keychain rejects every call (-34018) and login cannot work.
# They are read here, before the copy is modified, and embedded further down.
codesign -d --entitlements - --xml "$src" 2>/dev/null > build/sim/entitlements.xml || true
codesign -d --entitlements - --der "$src" 2>/dev/null > build/sim/entitlements.der || true
[ -s build/sim/entitlements.xml ] && [ -s build/sim/entitlements.der ] ||
  { echo "error: could not read entitlements from $src" >&2; exit 1; }

cp -a "$src" "$out"
rm -rf "$out/PlugIns" "$out/Extensions" "$out/Watch" "$out/_CodeSignature" "$out/SC_Info"
# Files unpacked from a downloaded IPA are quarantined; the simulator refuses to spawn those.
xattr -cr "$out"

sdk=$(xcrun --sdk iphonesimulator --show-sdk-version)
count=0
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q 'Mach-O' || continue
  minos=$(vtool -show-build "$file" | awk '$1 == "minos" { print $2; exit }')
  vtool -set-build-version iossim "${minos:-16.0}" "$sdk" -replace -output "$file" "$file" 2>/dev/null
  count=$((count + 1))
done < <(find "$out" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)

scripts/build-safari-extension.sh "$out" sim
mkdir -p "$out/PlugIns" && mv build/sim/OpenInReddit.appex "$out/PlugIns/"

exe="$out/$(plutil -extract CFBundleExecutable raw "$out/Info.plist")"
scripts/add-sim-entitlements.py "$exe" build/sim/entitlements.xml build/sim/entitlements.der

# Sign inside out: nested code first, the app bundle last.
find "$out" -depth \( -name '*.dylib' -o -name '*.framework' -o -name '*.appex' \) -print0 | xargs -0 codesign -f -s - 2>/dev/null
codesign -f -s - "$out"

echo "converted $count binaries -> $out"
