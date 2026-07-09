#!/usr/bin/env bash
# build-rust.sh: Rust → staticlib → XCFramework (sim + device) + UniFFI Swift bindings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEZTERM_DIR="$(cd "$SCRIPT_DIR/../wezterm" && pwd)"
IOS_DIR="$SCRIPT_DIR"
GENERATED_DIR="$IOS_DIR/WeztermMobile/Generated"
XCFW="$IOS_DIR/WeztermIOSCore.xcframework"

export PATH="$HOME/.cargo/bin:$PATH"

echo "=== Building Rust staticlib for aarch64-apple-ios-sim ==="
cd "$WEZTERM_DIR"
cargo build -p wezterm-ios-core --release --target aarch64-apple-ios-sim

echo "=== Building Rust staticlib for aarch64-apple-ios (device) ==="
cargo build -p wezterm-ios-core --release --target aarch64-apple-ios

SIM_LIB="$WEZTERM_DIR/target/aarch64-apple-ios-sim/release/libwezterm_ios_core.a"
DEVICE_LIB="$WEZTERM_DIR/target/aarch64-apple-ios/release/libwezterm_ios_core.a"

echo "=== Generating UniFFI Swift bindings ==="
cargo run -p wezterm-ios-core --bin uniffi-bindgen -- \
    generate \
    --library target/aarch64-apple-ios-sim/release/libwezterm_ios_core.dylib \
    --language swift \
    --out-dir "$GENERATED_DIR"

# uniffi generates .h and .modulemap; copy to a headers dir for xcframework
HEADERS_DIR="$IOS_DIR/include"
mkdir -p "$HEADERS_DIR"
cp "$GENERATED_DIR/wezterm_ios_coreFFI.h" "$HEADERS_DIR/"
cp "$GENERATED_DIR/wezterm_ios_coreFFI.modulemap" "$HEADERS_DIR/module.modulemap"

echo "=== Creating XCFramework (sim + device slices) ==="
rm -rf "$XCFW"
xcodebuild -create-xcframework \
    -library "$SIM_LIB" \
    -headers "$HEADERS_DIR" \
    -library "$DEVICE_LIB" \
    -headers "$HEADERS_DIR" \
    -output "$XCFW"

echo "=== Done: $XCFW ==="
echo ""
echo "XCFramework slices:"
plutil -p "$XCFW/Info.plist" | grep -E 'LibraryIdentifier|SupportedPlatform'
