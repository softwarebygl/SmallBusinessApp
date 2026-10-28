#!/bin/bash
set -e

echo "🚀 Starting App Store Connect Upload process for Small Business..."

ASC_KEY_ID="2JTL2WV5XC"
ASC_ISSUER_ID="46562150-20c4-4489-81db-12f330fcf7bc"

# 1. Load secrets if present, or fallback to user keys
if [ -f "secrets/tokens.env" ]; then
    export $(grep -v '^#' secrets/tokens.env | xargs)
fi

KEY_FILE="/Users/adriangutierrez/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
if [ ! -f "$KEY_FILE" ] && [ -f "$PWD/secrets/AuthKey_${ASC_KEY_ID}.p8" ]; then
    KEY_FILE="$PWD/secrets/AuthKey_${ASC_KEY_ID}.p8"
fi

if [ ! -f "$KEY_FILE" ]; then
    echo "❌ Error: API Key file $KEY_FILE not found!"
    exit 1
fi

BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/GLSmallBusiness.xcarchive"
EXPORT_PATH="$BUILD_DIR/exported"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"

mkdir -p "$BUILD_DIR"

cat <<PLIST > "$EXPORT_OPTIONS"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>T77JR9H9SB</string>
    <key>manageAppVersionAndBuildNumber</key>
    <true/>
</dict>
</plist>
PLIST

echo "🔍 Reading current build version..."
BUILD_VERSION=$(xcodebuild -showBuildSettings -project GLSmallBusiness.xcodeproj -configuration Release 2>/dev/null | grep 'CURRENT_PROJECT_VERSION =' | awk '{print $3}' | head -n 1)
echo "📦 Build Version: $BUILD_VERSION"

echo "📦 Archiving Small Business..."
xcodebuild clean archive \
    -project GLSmallBusiness.xcodeproj \
    -scheme GLSmallBusiness \
    -destination "generic/platform=iOS" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -quiet

echo "📦 Exporting the .ipa..."
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$EXPORT_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY_FILE" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    -quiet

IPA_PATH=$(find "$EXPORT_PATH" -name "*.ipa" | head -n 1)

if [ -z "$IPA_PATH" ]; then
    echo "❌ Error: .ipa file not found!"
    exit 1
fi

echo "🚀 Uploading Small Business to App Store Connect intake..."
xcrun altool --upload-app \
    -f "$IPA_PATH" \
    -t ios \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID"

echo "✅ Binary uploaded. Initiating automatic push to TestFlight..."
python3 "$(dirname "$0")/distribute_testflight.py" --app mb --version "$BUILD_VERSION"
