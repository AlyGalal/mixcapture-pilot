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
  'AshrafMMahdy/futo-egyptian-arabic-models 0b4a13bc110d51207d971178c9bb054475cb3c62 small_egy_acft_q8_0.bin fe6a363bd52bb07c968c515d29461ad28c233a283bf51527e2070e931d6470fc' \
  'eliasbatshon/mktub-whisper-codeswitch-ggml ec43229722f37dc233fce436609f671c7725bc99 ggml-codeswitch-medium-q8_0.bin 42ad913750c5487f8fb7bb9d45033fc06443d59d387c797b02632f639d46fbdd'; do
  read -r repo revision file digest <<< "$entry"
  path="build/probe/$file"
  curl -fLsS --retry 3 "https://huggingface.co/$repo/resolve/$revision/$file" -o "$path"
  printf '%s  %s\n' "$digest" "$path" | shasum -a 256 -c -
  for profile in 'auto on greedy' 'auto off greedy' 'ar off beam5'; do
    read -r language prompt decoding <<< "$profile"
    WHISPER_MODEL_PATH="$(pwd)/$path" WHISPER_PROBE_PROMPT="$prompt" \
      WHISPER_PROBE_LANGUAGE="$language" WHISPER_PROBE_DECODING="$decoding" \
      build/probe/WhisperProbe build/probe/arzen.wav | tee -a build/probe/results.log
  done
done
