#!/bin/bash

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
APPLICATION_NAME=Geranium
NEW_NAME="DeviceUtility"
NEW_DISPLAY_NAME="Device Utility"
NEW_BUNDLE_ID="com.system.deviceutility"
CONFIGURATION=Release

rm -rf build
mkdir -p build
cd build

if [ -e "$NEW_NAME.tipa" ]; then
    rm $NEW_NAME.tipa
fi

# Build .app
xcodebuild -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
    -scheme Geranium \
    -configuration Debug \
    -derivedDataPath "$WORKING_LOCATION/build/DerivedData" \
    -destination 'generic/platform=iOS' \
    ONLY_ACTIVE_ARCH="NO" \
    CODE_SIGNING_ALLOWED="NO" \
    PRODUCT_BUNDLE_IDENTIFIER="$NEW_BUNDLE_ID"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedData/Build/Products/$CONFIGURATION-iphoneos/$APPLICATION_NAME.app"
TARGET_APP="$WORKING_LOCATION/build/$NEW_NAME.app"
cp -r "$DD_APP_PATH" "$TARGET_APP"

# Remove signature
codesign --remove "$TARGET_APP" 2>/dev/null || true
rm -rf "$TARGET_APP/_CodeSignature"
rm -rf "$TARGET_APP/embedded.mobileprovision"

# Patch Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_BUNDLE_ID" "$TARGET_APP/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $NEW_BUNDLE_ID" "$TARGET_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $NEW_DISPLAY_NAME" "$TARGET_APP/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $NEW_DISPLAY_NAME" "$TARGET_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $NEW_NAME" "$TARGET_APP/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $NEW_NAME" "$TARGET_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $NEW_NAME" "$TARGET_APP/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $NEW_NAME" "$TARGET_APP/Info.plist"

mv "$TARGET_APP/$APPLICATION_NAME" "$TARGET_APP/$NEW_NAME"

# Build RootHelper
if [ -d "$WORKING_LOCATION/RootHelper" ]; then
    git submodule update --init --recursive 2>/dev/null || true
    cd "$WORKING_LOCATION/RootHelper"
    make clean 2>/dev/null || true
    make 2>/dev/null || true
    if [ -f "$WORKING_LOCATION/RootHelper/.theos/obj/debug/GeraniumRootHelper" ]; then
        cp "$WORKING_LOCATION/RootHelper/.theos/obj/debug/GeraniumRootHelper" "$TARGET_APP/SysHelper"
    fi
    cd -
fi

# ldid
if ! command -v ldid &> /dev/null; then
    if command -v brew &> /dev/null; then
        brew install ldid
    fi
fi

# Add entitlements
if command -v ldid &> /dev/null; then
    echo "Adding entitlements..."
    ldid -S"$WORKING_LOCATION/entitlements.plist" "$TARGET_APP/$NEW_NAME"
    if [ -f "$TARGET_APP/SysHelper" ]; then
        ldid -S"$WORKING_LOCATION/entitlements.plist" "$TARGET_APP/SysHelper"
    fi
fi

# Package .tipa
rm -rf Payload
mkdir Payload
cp -r "$NEW_NAME.app" "Payload/$NEW_NAME.app"
zip -vr "$NEW_NAME.tipa" Payload
rm -rf "$NEW_NAME.app"
rm -rf Payload

echo ""
echo "========================================="
echo " Build complete: build/$NEW_NAME.tipa"
echo "========================================="
