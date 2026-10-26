#!/bin/bash
# Native iPhone-simulator UI tests with reviewable screenshots.
# Needs build/Whisper/whisper.xcframework + small_egy_acft_q8_0.bin (scripts/build-unsigned.sh
# downloads them before this runs). Creates and deletes its own simulator; no downloads here.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build

SIM_NAME='MixCaptureUI'
RESULT_BUNDLE='build/UIResults.xcresult'
SCREENSHOTS='build/ui-screenshots'
LOG='build/ui-tests.log'
UDID=''

cleanup() {
  # Delete ONLY the simulator this script created.
  if [ -n "$UDID" ]; then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
  fi
  return 0
}
trap cleanup EXIT

test -d build/Whisper/whisper.xcframework || { echo 'Missing build/Whisper/whisper.xcframework; run scripts/build-unsigned.sh first.' >&2; exit 1; }
test -f build/Whisper/small_egy_acft_q8_0.bin || { echo 'Missing Whisper model; run scripts/build-unsigned.sh first.' >&2; exit 1; }

# The Xcode project references the generated icon catalog.
swift scripts/make-icon.swift build

# Pick the newest installed iOS 26+ runtime and iPhone 13 Pro Max (else the closest Pro Max it supports).
xcrun simctl list runtimes --json > build/sim-runtimes.json
xcrun simctl list devicetypes --json > build/sim-devicetypes.json
selection="$(python3 - <<'PY'
import json, re, sys

runtimes = json.load(open('build/sim-runtimes.json'))['runtimes']
types = json.load(open('build/sim-devicetypes.json'))['devicetypes']

def version(r):
    return tuple(int(p) for p in re.findall(r'\d+', r.get('version', '0')))

ios = [r for r in runtimes
       if r.get('isAvailable', False) and r.get('platform', 'iOS') == 'iOS' and version(r)[:1] >= (26,)]
if not ios:
    sys.exit('No available iOS 26+ simulator runtime is installed.')
runtime = max(ios, key=version)
supported = {t['identifier'] for t in runtime.get('supportedDeviceTypes', [])}
phones = [t for t in types if t['identifier'] in supported and t['name'].startswith('iPhone')]

def generation(t):
    m = re.search(r'iPhone (\d+)', t['name'])
    return int(m.group(1)) if m else 0

wanted = [t for t in phones if t['name'] == 'iPhone 13 Pro Max']
if not wanted:
    pro_max = [t for t in phones if 'Pro Max' in t['name']]
    wanted = sorted(pro_max, key=lambda t: abs(generation(t) - 13))[:1]
if not wanted:
    sys.exit('No Pro Max iPhone simulator type is supported by ' + runtime['name'])
print(wanted[0]['identifier'], runtime['identifier'], wanted[0]['name'], runtime['name'], sep='|')
PY
)"
IFS='|' read -r DEVICE_TYPE RUNTIME DEVICE_NAME RUNTIME_NAME <<< "$selection"
echo "Using $DEVICE_NAME on $RUNTIME_NAME"

UDID="$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE" "$RUNTIME")"
echo "Created simulator $UDID"
xcrun simctl boot "$UDID"

# bootstatus can hang if the simulator never finishes booting; cap it at 10 minutes.
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 &
boot_pid=$!
waited=0
while kill -0 "$boot_pid" 2>/dev/null; do
  if [ "$waited" -ge 600 ]; then
    kill "$boot_pid" 2>/dev/null || true
    echo 'Simulator did not finish booting in 10 minutes.' >&2
    exit 1
  fi
  sleep 2
  waited=$((waited + 2))
done
wait "$boot_pid" || { echo 'Simulator boot failed.' >&2; exit 1; }

rm -rf "$RESULT_BUNDLE" "$SCREENSHOTS"
mkdir -p "$SCREENSHOTS"

set +e
xcodebuild \
  -project MixCapture.xcodeproj \
  -scheme MixCapture \
  -configuration Debug \
  -destination "id=$UDID" \
  -derivedDataPath build/UITestDerivedData \
  -resultBundlePath "$RESULT_BUNDLE" \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 240 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  test 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

# Always export attachments, even after failures, so screenshots can be reviewed.
if [ -d "$RESULT_BUNDLE" ]; then
  xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" --output-path "$SCREENSHOTS" \
    || echo 'xcresulttool attachment export failed' >&2
  python3 - "$SCREENSHOTS" <<'PY' || true
import json, os, re, sys

root = sys.argv[1]
manifest = os.path.join(root, 'manifest.json')
if os.path.exists(manifest):
    for entry in json.load(open(manifest)):
        for att in entry.get('attachments', []):
            src = os.path.join(root, att.get('exportedFileName', ''))
            name = att.get('suggestedHumanReadableName') or ''
            if not os.path.isfile(src) or not name:
                continue
            ext = os.path.splitext(src)[1]
            # Strip the "_0_<UUID>" suffix Xcode appends so files read as 01-home.png.
            clean = re.sub(r'_\d+_[0-9A-Fa-f-]{36}$', '', os.path.splitext(name)[0])
            clean = re.sub(r'[^\w.-]+', '_', clean)
            os.replace(src, os.path.join(root, clean + ext))
PY
fi

if [ "$status" -eq 0 ]; then
  shots="$(find "$SCREENSHOTS" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
  echo "Exported $shots screenshots to $SCREENSHOTS"
  if [ "$shots" -lt 6 ]; then
    echo "Expected at least 6 screenshots, found $shots." >&2
    exit 1
  fi
fi
exit "$status"
