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
swiftc -parse-as-library MixCapture/LocalItems.swift MixCapture/Organizer.swift Tests/LocalItemsChecks.swift \
  -o build/items-checks
build/items-checks | tee build/items-checks.log
swiftc -parse-as-library MixCapture/LocalItems.swift MixCapture/Organizer.swift Tests/OrganizerChecks.swift \
  -o build/organizer-checks
build/organizer-checks | tee build/organizer-checks.log
swiftc -parse-as-library MixCapture/LocalItems.swift MixCapture/Organizer.swift Tests/OrganizerAdversarialChecks.swift \
  -o build/organizer-adversarial-checks
build/organizer-adversarial-checks | tee build/organizer-adversarial-checks.log
swiftc -parse-as-library MixCapture/LocalItems.swift MixCapture/Organizer.swift Tests/NotificationChecks.swift \
  -framework UserNotifications -o build/notification-checks
build/notification-checks | tee build/notification-checks.log

# App icon is generated natively with CoreGraphics (no bitmap/SVG assets in the repo).
swift scripts/make-icon.swift build

# Pinned official binary and multilingual weights. Downloads happen only at build time.
mkdir -p build/Whisper
curl --fail --location --retry 3 \
  'https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.2/whisper-v1.8.2-xcframework.zip' \
  -o build/Whisper/framework.zip
printf '%s  %s\n' '3ffeec1df254d908f01ee3d87bf0aedb8fbc8f29cbf50dc8702741bb85381385' \
  'build/Whisper/framework.zip' | shasum -a 256 -c -
unzip -q -o build/Whisper/framework.zip -d build/Whisper/unpacked
ditto build/Whisper/unpacked/build-apple/whisper.xcframework build/Whisper/whisper.xcframework
curl --fail --location --retry 3 \
  'https://huggingface.co/AshrafMMahdy/futo-egyptian-arabic-models/resolve/0b4a13bc110d51207d971178c9bb054475cb3c62/small_egy_acft_q8_0.bin' \
  -o build/Whisper/small_egy_acft_q8_0.bin
printf '%s  %s\n' 'fe6a363bd52bb07c968c515d29461ad28c233a283bf51527e2070e931d6470fc' \
  'build/Whisper/small_egy_acft_q8_0.bin' | shasum -a 256 -c -
printf '%s\n' 'whisper.cpp 1.8.2; Egyptian-CS small-Q8; model SHA256 fe6a363bd52bb07c968c515d29461ad28c233a283bf51527e2070e931d6470fc' \
  >> build/build-info.txt

# The ArzEn authors publish this 4.72-second Egyptian Arabic/English example at
# https://sites.google.com/view/arzen-corpus/resources . Download for CI evaluation only;
# never package this recording in the app or publish it as an artifact.
curl --fail --location --retry 3 \
  'https://drive.google.com/uc?export=download&id=1WSf0UNZZ6B57XC5Vd_R0VjyGxHIjxFqu' \
  -o build/Whisper/arzen-example.wav
printf '%s  %s\n' '5061de78839208537dca090724069341750dffc55e220d81f20d63bdf244a164' \
  'build/Whisper/arzen-example.wav' | shasum -a 256 -c -
/usr/bin/afconvert -f m4af -d aac@44100 -c 2 build/Whisper/arzen-example.wav build/Whisper/arzen-stereo.m4a
smoke='build/WhisperSmoke.app/Contents'
mkdir -p "$smoke/MacOS" "$smoke/Resources" "$smoke/Frameworks"
cp build/Whisper/small_egy_acft_q8_0.bin "$smoke/Resources/"
ditto build/Whisper/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$smoke/Frameworks/whisper.framework"
cat > "$smoke/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>WhisperSmoke</string><key>CFBundleIdentifier</key><string>com.mixcapture.smoke</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
swiftc -parse-as-library -target "$(uname -m)-apple-macos26.0" \
  -F "$smoke/Frameworks" -framework whisper -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  MixCapture/CaptureRecord.swift MixCapture/LocalTranscriber.swift MixCapture/WhisperTranscriber.swift \
  Tests/WhisperSmoke.swift -o "$smoke/MacOS/WhisperSmoke"
"$smoke/MacOS/WhisperSmoke" build/Whisper/arzen-example.wav build/Whisper/arzen-stereo.m4a \
  | tee build/whisper-smoke.log

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
test -f "$app/Frameworks/whisper.framework/whisper"
test -f "$app/small_egy_acft_q8_0.bin"
printf '%s  %s\n' 'fe6a363bd52bb07c968c515d29461ad28c233a283bf51527e2070e931d6470fc' \
  "$app/small_egy_acft_q8_0.bin" | shasum -a 256 -c -
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" \
  >> build/build-info.txt
mkdir -p build/package/Payload
ditto "$app" build/package/Payload/MixCapture.app
ditto -c -k --keepParent build/package/Payload build/MixCapture-unsigned.ipa
shasum -a 256 build/MixCapture-unsigned.ipa > build/SHA256SUMS.txt
echo 'Created build/MixCapture-unsigned.ipa; sign it on the device installation path.'
