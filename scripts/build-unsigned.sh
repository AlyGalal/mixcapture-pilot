#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build
{
  xcodebuild -version
  xcrun --sdk iphoneos --show-sdk-version
  git rev-parse HEAD
} > build/build-info.txt

swiftc -parse-as-library MixCapture/CaptureRecord.swift Tests/ModelChecks.swift \
  -o build/model-checks
build/model-checks | tee build/model-checks.log

xcodebuild \
  -project MixCapture.xcodeproj \
  -scheme MixCapture \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build | tee build/xcodebuild.log

app='build/DerivedData/Build/Products/Release-iphoneos/MixCapture.app'
test -f "$app/Info.plist"
test -f "$app/MixCapture"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" \
  >> build/build-info.txt
mkdir -p build/package/Payload
ditto "$app" build/package/Payload/MixCapture.app
ditto -c -k --keepParent build/package/Payload build/MixCapture-unsigned.ipa
shasum -a 256 build/MixCapture-unsigned.ipa > build/SHA256SUMS.txt
echo 'Created build/MixCapture-unsigned.ipa; sign it on the device installation path.'
