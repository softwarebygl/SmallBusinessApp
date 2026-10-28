#!/bin/bash
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
APP_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$APP_REPO/GLSmallBusiness.xcodeproj"
SCHEME="GLSmallBusiness"
DERIVED="/tmp/mb-shots-ipad-stripe/DerivedData"

xcodebuild build-for-testing \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath "$DERIVED" -quiet

RUNFILE=$(find "$DERIVED" -name "*.xctestrun" | head -n 1)

plutil -insert TestConfigurations.0.TestTargets.1.TestingEnvironmentVariables -dictionary -xml "
<dict>
  <key>MB_SCREENS</key><string>stripe</string>
  <key>MB_BRAND</key><string>0</string>
  <key>MB_DARK</key><string>0</string>
  <key>MB_LANDSCAPE</key><string>1</string>
  <key>MB_MARKETING</key><string>1</string>
</dict>" "$RUNFILE"

xcodebuild test-without-building -xctestrun "$RUNFILE" -destination "name=iPad Pro 13-inch (M5)" -derivedDataPath "$DERIVED" -resultBundlePath "/tmp/mb-shots-ipad-stripe/result.xcresult"
