#!/bin/bash

set -e

cd "$(dirname "$0")"

WORKING_LOCATION="$(pwd)"
APPLICATION_NAME=Geranium
NEW_NAME="CompassPro"
NEW_DISPLAY_NAME="Compass Pro"
NEW_BUNDLE_ID="com.compasspro.app"
CONFIGURATION=Release

rm -rf build
mkdir -p build
cd build

if [ -e "$NEW_NAME.tipa" ]; then
    rm -f "$NEW_NAME.tipa"
fi
if [ -e "$NEW_NAME.ipa" ]; then
    rm -f "$NEW_NAME.ipa"
fi

# Build .app
echo "Building with xcodebuild ($CONFIGURATION)..."
xcodebuild -project "$WORKING_LOCATION/$APPLICATION_NAME.xcodeproj" \
    -scheme Geranium \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$WORKING_LOCATION/build/DerivedData" \
    -destination 'generic/platform=iOS' \
    ONLY_ACTIVE_ARCH="NO" \
    CODE_SIGNING_ALLOWED="NO" \
    PRODUCT_BUNDLE_IDENTIFIER="$NEW_BUNDLE_ID"

DD_APP_PATH="$WORKING_LOCATION/build/DerivedData/Build/Products/$CONFIGURATION-iphoneos/$APPLICATION_NAME.app"
TARGET_APP="$WORKING_LOCATION/build/$NEW_NAME.app"

if [ ! -d "$DD_APP_PATH" ]; then
    echo "Error: App bundle not found at $DD_APP_PATH"
    ls -la "$WORKING_LOCATION/build/DerivedData/Build/Products/" || true
    exit 1
fi

cp -r "$DD_APP_PATH" "$TARGET_APP"

# Remove signature
echo "Removing old signatures..."
codesign --remove "$TARGET_APP" 2>/dev/null || true
rm -rf "$TARGET_APP/_CodeSignature"
rm -rf "$TARGET_APP/embedded.mobileprovision"

# Patch Info.plist
echo "Patching Info.plist for $NEW_DISPLAY_NAME ($NEW_BUNDLE_ID)..."
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_BUNDLE_ID" "$TARGET_APP/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $NEW_BUNDLE_ID" "$TARGET_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $NEW_DISPLAY_NAME" "$TARGET_APP/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $NEW_DISPLAY_NAME" "$TARGET_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $NEW_NAME" "$TARGET_APP/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $NEW_NAME" "$TARGET_APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $NEW_NAME" "$TARGET_APP/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $NEW_NAME" "$TARGET_APP/Info.plist"

mv "$TARGET_APP/$APPLICATION_NAME" "$TARGET_APP/$NEW_NAME"

# ldid
if ! command -v ldid &> /dev/null; then
    if command -v brew &> /dev/null; then
        echo "Installing ldid via brew..."
        brew install ldid || true
    fi
fi

# Add entitlements
if command -v ldid &> /dev/null; then
    echo "Adding entitlements with ldid..."
    ldid -S"$WORKING_LOCATION/entitlements.plist" "$TARGET_APP/$NEW_NAME"
else
    echo "ldid not found, skipping entitlement pseudo-signing"
fi

# Package .ipa and .tipa
echo "Packaging into IPA / TIPA..."
rm -rf Payload
mkdir Payload
cp -r "$NEW_NAME.app" "Payload/$NEW_NAME.app"
zip -vr "$NEW_NAME.tipa" Payload
cp "$NEW_NAME.tipa" "$NEW_NAME.ipa"
rm -rf "$NEW_NAME.app"
rm -rf Payload

echo ""
echo "========================================="
echo " Build complete: build/$NEW_NAME.ipa and build/$NEW_NAME.tipa"
echo "========================================="
