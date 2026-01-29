#!/bin/bash

# Build Happy Manager for macOS
# Run this script from the HappyManager directory

set -e

echo "🔨 Building Happy Manager..."

# Build the app in Release mode
xcodebuild -project HappyManager.xcodeproj \
    -scheme HappyManager \
    -configuration Release \
    -derivedDataPath ./build \
    clean build

# Find and copy the built app
APP_PATH="./build/Build/Products/Release/HappyManager.app"

if [ -d "$APP_PATH" ]; then
    echo "✅ Build successful!"
    echo ""
    echo "📦 App location: $APP_PATH"
    echo ""
    echo "To install:"
    echo "  1. Copy HappyManager.app to /Applications"
    echo "  2. Open it once to allow in System Settings > Privacy & Security"
    echo "  3. It will appear in your menu bar"
    echo ""
    echo "Or run directly:"
    echo "  open \"$APP_PATH\""
else
    echo "❌ Build failed - app not found at expected location"
    exit 1
fi
