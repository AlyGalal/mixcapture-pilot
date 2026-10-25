#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/probe
curl -fLsS --retry 3 'https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.2/whisper-v1.8.2-xcframework.zip' -o build/probe/framework.zip
printf '%s  %s\n' '3ffeec1df254d908f01ee3d87bf0aedb8fbc8f29cbf50dc8702741bb85381385' 'build/probe/framework.zip' | shasum -a 256 -c -
unzip -q -o build/probe/framework.zip -d build/probe
curl -fLsS --retry 3 'https://drive.google.com/uc?export=download&id=1WSf0UNZZ6B57XC5Vd_R0VjyGxHIjxFqu' -o build/probe/arzen.wav
printf '%s  %s\n' '5061de78839208537dca090724069341750dffc55e220d81f20d63bdf244a164' 'build/probe/arzen.wav' | shasum -a 256 -c -
frameworks='build/probe/build-apple/whisper.xcframework/macos-arm64_x86_64'
swiftc -parse-as-library -D WHISPER_PROBE -target "$(uname -m)-apple-macos26.0" \
  -F "$frameworks" -framework whisper -Xlinker -rpath -Xlinker "$(pwd)/$frameworks" \
  MixCapture/CaptureRecord.swift MixCapture/LocalTranscriber.swift MixCapture/WhisperTranscriber.swift \
  Tests/WhisperProbe.swift -o build/probe/WhisperProbe
for entry in \
  'small-q5_1 ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb' \
  'large-v3-turbo-q5_0 394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2' \
  'medium-q5_0 19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f'; do
  read -r model digest <<< "$entry"
  path="build/probe/ggml-$model.bin"
  curl -fLsS --retry 3 "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-$model.bin" -o "$path"
  printf '%s  %s\n' "$digest" "$path" | shasum -a 256 -c -
  for prompt in on off; do
    WHISPER_MODEL_PATH="$(pwd)/$path" WHISPER_PROBE_PROMPT="$prompt" \
      build/probe/WhisperProbe build/probe/arzen.wav | tee -a build/probe/results.log
  done
done
