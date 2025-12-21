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
# We sign with - (ad-hoc) or a specific identity if available. 
# Ideally, for the framework distribution, we sign with proper entitlements.
# When the consumer archives, Xcode will re-sign, preserving these entitlements.
echo "Signing MacDirectUpdater.app..."
ENTITLEMENTS="$FRAMEWORK_ROOT/Sources/UpdateHelper/MacDirectUpdater.entitlements"
codesign --force --options runtime --deep --sign - --entitlements "$ENTITLEMENTS" "$OUTPUT_DIR/$UPDATER_APP_NAME"

echo "MacDirectUpdater.app created and signed at $OUTPUT_DIR/$UPDATER_APP_NAME"
echo "Done."
