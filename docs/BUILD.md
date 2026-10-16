# Building the app

## Prerequisites (build machine: macOS)

```bash
# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

# Xcode 16+ (from the App Store or developer.apple.com), then:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -downloadPlatform iOS       # simulator runtime, if missing

# xcodegen (the .xcodeproj is generated, never hand-edited)
brew install xcodegen
```

## 1. Rust core → XCFramework

```bash
cd ios
./build-rust.sh
```

This builds `wezterm-ios-core` for `aarch64-apple-ios-sim` **and** `aarch64-apple-ios`,
generates the UniFFI Swift bindings into `ios/WeztermMobile/Generated/`, and assembles
`ios/WeztermIOSCore.xcframework` with both slices.

First build compiles the whole vendored wezterm workspace — expect several minutes.

## 2. Generate the Xcode project

```bash
cd ios
xcodegen
```

Note: `project.yml` includes the whole `WeztermMobile/` directory as sources, so new
Swift files are picked up by re-running `xcodegen` — never edit the `.xcodeproj`.

## 3. Simulator build (no signing needed)

```bash
xcodebuild -project WeztermMobile.xcodeproj -scheme WeztermMobile \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  build CODE_SIGNING_ALLOWED=NO

xcrun simctl boot 'iPhone 16 Pro'
open -a Simulator
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'WeztermMobile.app' -path '*iphonesimulator*' | head -1)
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.example.weztermmobile
```

The simulator shares the Mac's network — if the Mac's Tailscale is connected, the app
can reach your tailnet directly.

Building with `-destination 'generic/platform=iOS Simulator'` (no concrete device) also
tries to link an x86_64 slice, which the XCFramework does not contain; add
`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` in that case.

Launch arguments for automated checks (all require a saved connection):
`--autoconnect` (connect to the first saved server), `--attach-pane <id>`,
`--split-pane <id> right|down` (split that pane and open the new one) and `--new-tab`
(new tab in the first window). Example: `xcrun simctl launch booted dev.nyaga.weztermmobile --autoconnect --split-pane 0 down`. Simulator quirks (click-drag scrolling, hardware
keyboard capture) are covered in TROUBLESHOOTING.md.

## 4. Device build (signing required)

One-time setup:

1. Xcode → Settings → Accounts → add your Apple ID (a free account works)
2. Select the account → *Manage Certificates…* → `+` → *Apple Development*
3. Connect the iPhone via USB, unlock it, tap *Trust*
4. Pair (if `xcodebuild` complains about pairing):
   `xcrun devicectl manage pair --device <device-id>` — device IDs via
   `xcrun devicectl list devices`
5. On the iPhone: Settings → Privacy & Security → **Developer Mode** → on (reboots)

Find your team ID (the `OU=` field):

```bash
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

Build **targeting the concrete device** (a `generic/platform=iOS` destination fails
with "team has no devices" on a fresh free account — targeting the real device
auto-registers it):

```bash
xcodebuild -project WeztermMobile.xcodeproj -scheme WeztermMobile \
  -configuration Release \
  -destination 'platform=iOS,id=<device-udid>' \
  DEVELOPMENT_TEAM=<team-id> -allowProvisioningUpdates \
  -derivedDataPath /tmp/wezterm-device-build build

xcrun devicectl device install app --device <device-id> \
  /tmp/wezterm-device-build/Build/Products/Release-iphoneos/WeztermMobile.app
```

First launch: Settings → General → VPN & Device Management → trust your developer app.

## Weekly routine: re-sign after the 7-day expiry (free account)

With a free Apple ID the signature dies every 7 days — the app stops launching (or
shows "Untrusted Developer"). The fix is a rebuild + reinstall; **app data (saved
connections, snippets) survives**.

```bash
# 1. rebuild (incremental; build-rust.sh NOT needed unless Rust changed)
cd ios
xcodebuild -project WeztermMobile.xcodeproj -scheme WeztermMobile \
  -configuration Release \
  -destination 'platform=iOS,id=<device-udid>' \
  DEVELOPMENT_TEAM=<team-id> -allowProvisioningUpdates \
  -derivedDataPath /tmp/wezterm-device-build build

# 2. install — no cable needed if the device shows "available (paired)":
xcrun devicectl list devices
xcrun devicectl device install app --device <device-id> \
  /tmp/wezterm-device-build/Build/Products/Release-iphoneos/WeztermMobile.app
```

- **No cable needed** once paired: `devicectl` installs over the same Wi-Fi.
  Plug in only if the device shows as unavailable.
- **Signing needs a GUI login session.** Run the `xcodebuild` step from Terminal.app
  (or any shell inside your logged-in desktop session). From ssh, a launchd
  background job, or an agent shell, the login keychain is locked and codesign fails
  with `User interaction is not allowed`.
- **If `devicectl` never pairs the device** (it lists only an ECID, no UDID, and
  `devicectl manage pair` reports no `RemotePairingDeviceRepresentation`), install
  over USB through the lockdown channel instead; this works even when Xcode's
  CoreDevice pairing is incomplete:

  ```bash
  brew install libimobiledevice ideviceinstaller
  idevicepair pair        # tap "Trust" on the phone
  ideviceinstaller install \
    /tmp/wezterm-device-build/Build/Products/Release-iphoneos/WeztermMobile.app
  ```
- After re-signing, iOS sometimes drops developer trust again. If launch is blocked:
  Settings → General → VPN & Device Management → your developer profile → Trust
  (the Trust button needs network connectivity).

## When do I need to rebuild?

| Change | Rebuild? |
|--------|----------|
| Swift/Rust code changes | yes (`build-rust.sh` only if Rust changed) |
| Free-account signature expired (7 days) | yes — rebuild + reinstall, data survives |
| Server-side changes (socat, tailscale, reboots) | **no** |
| Connection addresses changed | **no** — edit them in the app |

The cable is only needed for the `devicectl … install` step; the app runs fully
independently of the Mac afterwards.
