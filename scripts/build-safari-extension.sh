#!/bin/bash
# Builds the "Open in Reddit" Safari extension into build/[sim/]OpenInReddit.appex.
# It is unsigned; the IPA build embeds it and SideStore signs it with the app.
#
# Usage: scripts/build-safari-extension.sh path/to/Reddit.ipa-or-.app [sim]
#   sim: build for the iOS Simulator instead of a device
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: scripts/build-safari-extension.sh path/to/Reddit.ipa-or-.app [sim]}"
if [ -d "$app" ]; then
  info=$(plutil -convert xml1 -o - "$app/Info.plist")
else
  info=$(unzip -p "$app" 'Payload/*.app/Info.plist' | plutil -convert xml1 -o - -)
fi
value() { plutil -extract "$1" raw - <<<"$info"; }

if [ "${2:-}" = "sim" ]; then
  sdk=iphonesimulator target=arm64-apple-ios16.0-simulator platform=iPhoneSimulator out=build/sim/OpenInReddit.appex
else
  sdk=iphoneos target=arm64-apple-ios16.0 platform=iPhoneOS out=build/OpenInReddit.appex
fi

rm -rf "$out" && mkdir -p "$out"
cp SafariExtension/Resources/* "$out"
# An extension must carry the app's bundle ID as a prefix and its version numbers.
sed -e "s/APP_BUNDLE_ID/$(value CFBundleIdentifier)/" -e "s/APP_VERSION/$(value CFBundleShortVersionString)/" \
    -e "s/APP_BUILD/$(value CFBundleVersion)/" -e "s/PLATFORM_NAME/$platform/" \
    SafariExtension/Info.plist > "$out/Info.plist"
env -u SDKROOT xcrun --sdk "$sdk" clang -target "$target" -fobjc-arc -fapplication-extension -Os \
    -e _NSExtensionMain -framework Foundation SafariExtension/Handler.m -o "$out/OpenInReddit"
echo "built $out"
