# MixCapture

An experimental personal iPhone voice organizer with an Arabic RTL interface. Audio and transcription stay on the device. The bundled Egyptian Arabic/English Whisper small-Q8 model needs no runtime download or account.

Build 4 has Today, Library, Expenses and Settings. Explicit Arabic/English commands create notes, project tasks, shopping items, recipes, classified expenses, local notification reminders and local calendar items. Ambiguous, negated and unsupported commands enter a review queue. This is a deterministic local phrase interpreter, not general AI understanding. Original text and source receipts are retained; retries are idempotent and actions can be undone.

Calendar connection is optional and uses EventKit permission, with one-way creation and ownership-checked undo. Backup JSON merges additively with existing UUIDs winning; imported reminders and events are never automatically activated. Audio is shared separately. Keep the app installed when updating to preserve its local data.

Examples: `paid 120.50 EGP for Uber`, `remind me in 20 minutes to call Sam`, `add milk and eggs to shopping list Groceries`. Arabic examples and help are built into the app. Review transaction dates, amounts and notification status when testing.

Shortcuts provides Start Recording and Toggle Recording. For Back Tap, create a shortcut using Toggle Recording (or URL `mixcapture://toggle` followed by Open URLs), then select it in Settings > Accessibility > Touch > Back Tap. Unlock/foreground and microphone permission may be required. Local transcription is foreground-only, supports recordings up to 30 minutes, and does not guarantee every English word keeps Latin script.

## Build and verification

Requires Xcode/iOS SDK 26 or later on macOS. Public GitHub Actions builds without signing:

```
bash scripts/build-unsigned.sh
bash scripts/test-ui.sh
```

The pipeline runs Foundation model/money/state/parser checks, adversarial Arabic/English cases, a real Whisper smoke test against the public ArzEn sample (including repeatability, AAC conversion, silence and cancellation), a device build, and native simulator UI tests with screenshots. Synthetic UI fixtures exist only in Debug simulator builds with `--ui-testing`. No personal audio or data is in this repository or its artifacts. The public sample is evaluation-only and is not bundled.

The IPA is unsigned and requires signing through a sideloading tool. Real-device microphone, background behavior, notifications, EventKit permission and Back Tap still require device testing. Free developer provisioning requires periodic renewal. The bundled model and whisper.cpp licenses/attribution are in ThirdPartyNotices.txt.
