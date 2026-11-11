#!/bin/bash
# Build the unsigned CompassPro IPA from this checkout:
# the Rust library, an Xcode project generated from project.yml, a Release build with signing off, and the
# app zipped into Payload/.

set -euo pipefail
trap 'rc=$?; [ "$rc" = 0 ] || echo "error: build-ipa.sh stopped (exit $rc) at: $BASH_COMMAND" >&2' EXIT
if [ "${RUNNER_DEBUG:-}" = 1 ]; then set -x; fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="${BUNDLE_ID:-com.compasspro.app}"
OUTPUT="${OUTPUT:-$ROOT/build/CompassPro-iOS17.ipa}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
REBUILD_RUST="${REBUILD_RUST:-0}"
VERSION="${VERSION:-1.3.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_IOS_SDK="${MIN_IOS_SDK:-17.0}"

die() { echo "error: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }

case "$OUTPUT" in /*) ;; *) OUTPUT="$PWD/$OUTPUT" ;; esac
case "$DERIVED_DATA" in /*) ;; *) DERIVED_DATA="$PWD/$DERIVED_DATA" ;; esac
cd "$ROOT"

if [ -n "$VERSION" ]; then
  [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "VERSION must be up to three numbers, like 1.3.0 (got: $VERSION)"
fi
if [ -n "$BUILD_NUMBER" ]; then
  [[ "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "BUILD_NUMBER must be up to three numbers (got: $BUILD_NUMBER)"
fi

if [ -z "${DEVELOPER_DIR:-}" ]; then
  DEVELOPER_DIR="$(xcode-select -p)"
fi
export DEVELOPER_DIR

if ! command -v cargo >/dev/null && [ -f "$HOME/.cargo/env" ]; then
  set +u
  source "$HOME/.cargo/env" || true
  set -u
fi
command -v xcodegen >/dev/null || die "xcodegen isn't installed (brew install xcodegen)"
command -v cargo >/dev/null || die "Rust isn't installed (https://rustup.rs)"
echo "==> $(xcodebuild -version | tr '\n' ' ')"

sdk="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
[ -n "$sdk" ] || die "this Xcode has no iOS SDK"
echo "==> iOS SDK version: $sdk"

# --- Rust library -------------------------------------------------------------
if [ "$REBUILD_RUST" = 1 ] || [ ! -d SideInstallerFFI.xcframework ]; then
  if command -v rustup >/dev/null && ! rustup target list --installed | grep -qx aarch64-apple-ios; then
    rustup target add aarch64-apple-ios
  fi
  echo "==> Building the Rust library"
  SIMULATOR=0 bash ./build-rust.sh
else
  echo "==> Rust library: using the SideInstallerFFI.xcframework already here"
fi
[ -d SideInstallerFFI.xcframework ] || die "no SideInstallerFFI.xcframework after the Rust build"

# --- Xcode project ------------------------------------------------------------
echo "==> Generating CompassPro.xcodeproj from project.yml"
rm -rf CompassPro.xcodeproj
xcodegen generate --spec project.yml --quiet
pbx=CompassPro.xcodeproj/project.pbxproj
[ -f "$pbx" ] || die "xcodegen made no $pbx"

# --- App ----------------------------------------------------------------------
overrides=()
[ -n "$VERSION" ] && overrides+=("MARKETING_VERSION=$VERSION")
[ -n "$BUILD_NUMBER" ] && overrides+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
echo "==> Building CompassPro (Release, unsigned)"
find "$DERIVED_DATA" -name 'SideInstallerFFI-*.pcm' -delete 2>/dev/null || true

xcodebuild build \
  -project CompassPro.xcodeproj -scheme CompassPro -configuration Release \
  -destination 'generic/platform=iOS' -sdk iphoneos -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  ${overrides[@]+"${overrides[@]}"}

app="$DERIVED_DATA/Build/Products/Release-iphoneos/CompassPro.app"
[ -d "$app" ] || die "no CompassPro.app in $DERIVED_DATA/Build/Products/Release-iphoneos"
got="$(plist CFBundleIdentifier "$app/Info.plist")"
[ "$got" = "$BUNDLE_ID" ] || die "the built app's bundle id is $got, not $BUNDLE_ID"
version="$(plist CFBundleShortVersionString "$app/Info.plist")"

cp -f "$ROOT/ios-app/"*.png "$app/" 2>/dev/null || true

# --- IPA ----------------------------------------------------------------------
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload" "$(dirname "$OUTPUT")"
ditto "$app" "$stage/Payload/CompassPro.app"
find "$stage" -name .DS_Store -delete
rm -f "$OUTPUT"
(cd "$stage" && zip -qryX "$OUTPUT" Payload)

echo "==> Done: $OUTPUT ($(du -h "$OUTPUT" | cut -f1 | tr -d ' '))"
echo "    $BUNDLE_ID, version $version, unsigned"
echo "    sha256 $(shasum -a 256 "$OUTPUT" | cut -d' ' -f1)"
