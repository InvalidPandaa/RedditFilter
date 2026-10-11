# RedditFilter

An iOS tweak that filters unwanted content out of the official Reddit app: promoted posts, recommendations, NSFW posts, awards, scores, and AutoModerator comments.

This is a fork of [NicholasBly/RedditFilter](https://github.com/NicholasBly/RedditFilter), which continues [level3tjg/RedditFilter](https://github.com/level3tjg/RedditFilter). It adds what is needed to build and test the tweak locally on a Mac:

- a switch to turn off Reddit's automatic translations, and a "Clear cache" button
- a switch for the classic media viewer: swipe up for the comments and sideways for the next post, instead of the vertical post feed
- a switch to play Redgifs posts with sound: Reddit's own copy of these videos has no sound track, so the stream is taken from Redgifs when it is available and has sound
- switches to hide the "Games on Reddit", "Resources" and "Reddit Pro" sections of the side menu
- the settings open with a long press on the menu button (☰) of the profile screen
- one-command IPA build from a decrypted Reddit IPA
- running the patched app in the iOS Simulator on Apple Silicon
- unit tests for the filter logic that run natively on macOS
- login diagnostics for debug builds
- crash fixes in RedditSideloadFix, which is now part of this repository

## Status

| | |
|---|---|
| Reddit version | 2026.40.0 |
| Simulator (iOS 27.0) | App starts; login works with email and password, and with Google (Google so far only checked with `RF_NO_FILTER=1 RF_NO_PROBES=1`) |
| Sideloaded on a device | Builds; login not verified yet |

Reddit changes its GraphQL schema regularly, so filters can stop working after an app update. `Tests/run.sh` and the debug menu are there to notice that quickly.

## Requirements

- macOS on Apple Silicon with Xcode and an iOS Simulator runtime at least as new as the SDK the Reddit app was built with (iOS 27.0 for Reddit 2026.40.0)
- [Theos](https://theos.dev/docs/installation) in `~/theos`, or `THEOS` pointing to it
- The `jailed` Theos module from [level3tjg/theos-jailed](https://github.com/level3tjg/theos-jailed), copied to `$THEOS/mod/jailed`
- Rosetta (the module ships an x86_64 `insert_dylib`)
- `brew install ldid dpkg xz xmlstarlet libplist`
- A **decrypted** Reddit IPA. This repository does not contain one and cannot produce one.

## Build

```bash
git clone https://github.com/Vinceundco/RedditFilter
cd RedditFilter
scripts/build-ipa.sh path/to/Reddit-Decrypted.ipa          # release
scripts/build-ipa.sh path/to/Reddit-Decrypted.ipa debug    # with debug menu and diagnostics
```

The patched IPA lands in `packages/`. It is unsigned; install it with SideStore, AltStore or a similar tool.

For a jailbroken device, `make package` (rootful) or `make package THEOS_PACKAGE_SCHEME=rootless` builds a `.deb` instead.

## Run in the iOS Simulator

```bash
scripts/build-ipa.sh path/to/Reddit-Decrypted.ipa debug
scripts/make-sim-app.sh
xcrun simctl install booted build/sim/RedditApp.app
xcrun simctl launch booted com.reddit.Reddit
```

`scripts/run-sim.sh path/to/Reddit-Decrypted.ipa` does all four steps in one go and leaves out RedditSideloadFix.

`make-sim-app.sh` takes the patched device app and makes it loadable by the simulator:

1. switches every Mach-O from platform *iOS* to *iOS Simulator*,
2. embeds the app's entitlements in the executable (`scripts/add-sim-entitlements.py`), because without them every keychain call fails with `-34018` and login is impossible,
3. removes app extensions and quarantine flags, then signs ad hoc.

Things to know:

- The app exits when a debugger is attached. Use logs and crash reports in `~/Library/Logs/DiagnosticReports` instead.
- App Attest is unavailable in the simulator; Reddit falls back gracefully.
- `RedditSideloadFix` is not needed in the simulator, because the bundle ID is unchanged there. Delete `build/sim/RedditApp.app/Frameworks/RedditSideloadFix.dylib` and re-run `codesign -f -s - build/sim/RedditApp.app` to test without it.

## Tests

```bash
Tests/run.sh
```

Compiles `JSONFilter.m` for macOS and runs it against the JSON files in `Tests/Fixtures` (file name = GraphQL operation name). No device, simulator or Theos needed. The fixtures are hand-written to match the shapes the filter expects; replace them with captured responses when Reddit's schema changes.

## Debug builds

A build made with `debug` adds:

- the **debug menu** in the RedditFilter settings, showing which GraphQL paths still resolve,
- **diagnostics** (`LoginDebug.x`) written to the system log under the subsystem `com.redditfilter.debug`.

```bash
# Simulator
xcrun simctl spawn booted log stream --predicate 'subsystem == "com.redditfilter.debug"'
# Device: Console.app, filter by the same subsystem
```

| Prefix | Meaning |
|---|---|
| `[boot]` | Bundle ID as seen through each API, keychain probe (`-25300` = working, `-34018` = no entitlement) |
| `[net]` | Every request except media: method, host, path, HTTP status, names of attestation-related headers |
| `[attest]` | App Attest calls and their results |
| `[media]` | Address a video is played from, and when a player is muted or unmuted |
| `[error]` | `NSError`s created by the app's SDKs (reCAPTCHA, auth, Firebase, ...) |

Bodies and header values are never logged, so the log contains no passwords or tokens. The one exception are headers whose value is `enabled` or `disabled`, such as `X-Reddit-Translations`.

The app exits under a debugger, so debug builds can write their view hierarchy to a file instead:

```bash
xcrun simctl spawn booted notifyutil -p com.redditfilter.debug.dump
cat "$(xcrun simctl get_app_container booted com.reddit.Reddit data)/tmp/rf-ui-dump.txt"
```

Three more environment variables help to find out how Reddit switches a feature on:

```bash
# Save an operation's latest response to tmp/rf-<name>.json in the app container (may contain personal data)
SIMCTL_CHILD_RF_DUMP_OP=GetAllExperimentVariants xcrun simctl launch booted com.reddit.Reddit
# Save the latest response of every operation that contains a word, as tmp/rf-match-<name>.json
SIMCTL_CHILD_RF_DUMP_MATCH=redgifs xcrun simctl launch booted com.reddit.Reddit
# Hide every experiment whose name contains one of these words from the app
SIMCTL_CHILD_RF_DROP_EXP=ios_fbp_reimagine,ios_fbp_m2_m3 xcrun simctl launch booted com.reddit.Reddit
```

Two environment variables switch hooks off at launch, to check whether a problem is caused by the tweak itself:

```bash
SIMCTL_CHILD_RF_NO_FILTER=1 xcrun simctl launch booted com.reddit.Reddit   # no filter hooks
SIMCTL_CHILD_RF_NO_PROBES=1 xcrun simctl launch booted com.reddit.Reddit   # no network/attest logging hooks
```

## How it works

| File | Purpose |
|---|---|
| `Tweak.xm` | Hooks `NSURLSession`: passes GraphQL responses through the filter and rewrites the translation header; hides awards and scores on models |
| `JSONFilter.m` | The filter itself, including the list of experiments removed for the classic media viewer and the swap to the Redgifs stream. Pure Foundation, no UIKit or Reddit classes |
| `Settings.x`, `ModMenu.x`, `FeedFilterSettingsViewController.x` | The two ways into the settings (button in Reddit's settings, long press on the profile menu button) and the settings screen |
| `Redgifs.m`, `RedgifsViewer.x` | "Redgifs sound": checks which Redgifs videos are playable with sound, and stops the full-screen viewer from treating them as silent GIFs |
| `DrawerSections.x` | Removes hidden sections from the side menu's list before it is shown |
| `CacheCleaner.m` | Measures and empties the cache folder |
| `DebugMenu.x`, `LoginDebug.x`, `UIDump.x` | Debug builds only |
| `RedditSideloadFix/` | Makes the app work under a different bundle ID and team (keychain, app groups, reCAPTCHA) |
| `scripts/` | IPA build and simulator conversion |

The tweak uses the Logos `internal` generator, so it only needs the Objective-C runtime and no Substrate.

## Credits

- [level3tjg](https://github.com/level3tjg) for the original tweak and RedditSideloadFix
- [NicholasBly](https://github.com/NicholasBly) for the rework this fork is based on

## License and disclaimer

MIT, see [LICENSE](LICENSE).

This project is not affiliated with Reddit. Using a modified client may violate Reddit's User Agreement and can put your account at risk; use it at your own discretion.
