#!/bin/bash
set -e

# Configuration
FRAMEWORK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$FRAMEWORK_ROOT/.build/release"
UPDATER_APP_NAME="MacDirectUpdater.app"
UPDATER_BINARY_NAME="MacDirectUpdater"
OUTPUT_DIR="$FRAMEWORK_ROOT/Sources/Resources"

echo "Building MacDirectUpdater..."
cd "$FRAMEWORK_ROOT"
swift build -c release --product MacDirectUpdater

# Create App Bundle Structure
echo "Creating App Bundle..."
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/$UPDATER_APP_NAME"
mkdir -p "$OUTPUT_DIR/$UPDATER_APP_NAME/Contents/MacOS"
mkdir -p "$OUTPUT_DIR/$UPDATER_APP_NAME/Contents/Resources"

# Copy Binary
cp "$BUILD_DIR/$UPDATER_BINARY_NAME" "$OUTPUT_DIR/$UPDATER_APP_NAME/Contents/MacOS/"

# Copy Info.plist
cp "$FRAMEWORK_ROOT/Sources/UpdateHelper/Info.plist" "$OUTPUT_DIR/$UPDATER_APP_NAME/Contents/Info.plist"

# Set Permissions
chmod +x "$OUTPUT_DIR/$UPDATER_APP_NAME/Contents/MacOS/$UPDATER_BINARY_NAME"

# Code Sign
# Automatically detect Developer ID Application certificate for proper notarization support.
# Falls back to ad-hoc signing (-) if no Developer ID is found.
# When the consumer archives, Xcode will re-sign with their own identity.
echo "Signing MacDirectUpdater.app..."
ENTITLEMENTS="$FRAMEWORK_ROOT/Sources/UpdateHelper/MacDirectUpdater.entitlements"

# Find Developer ID Application certificate
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')

if [ -z "$SIGNING_IDENTITY" ]; then
    echo "No Developer ID Application certificate found, using ad-hoc signing."
    SIGNING_IDENTITY="-"
else
    echo "Found signing identity: $SIGNING_IDENTITY"
fi

codesign --force --options runtime --deep --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$OUTPUT_DIR/$UPDATER_APP_NAME"

echo "MacDirectUpdater.app created and signed at $OUTPUT_DIR/$UPDATER_APP_NAME"
echo "Done."
