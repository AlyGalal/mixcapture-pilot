# MixCapture

An experimental personal iPhone voice organizer with an English LTR interface. Audio and transcription stay on the device. The bundled Arabic/English code-switch Whisper medium-Q8 model needs no runtime download or account.

Build 5 uses English for navigation, forms, settings, dates, validation and permission messages while preserving Arabic/English input and original content.

Build 5 has Today, Library, Expenses and Settings. Explicit Arabic/English commands create notes, project tasks, shopping items, recipes, classified expenses, local notification reminders and local calendar items. Ambiguous, negated and unsupported commands enter a review queue. This is a deterministic local phrase interpreter, not general AI understanding. Original text and source receipts are retained; retries are idempotent and actions can be undone.

Calendar connection is optional and uses EventKit permission, with one-way creation and ownership-checked undo. It exports event titles/times rather than raw source transcripts; iOS may synchronize this metadata through configured calendar accounts. Backup JSON merges additively with existing UUIDs winning; imported reminders and events are never automatically activated. Audio is shared separately. Keep the app installed when updating to preserve its local data.

Examples: `paid 120.50 EGP for Uber`, `remind me in 20 minutes to call Sam`, `add milk and eggs to shopping list Groceries`. Arabic voice-command examples are included; the interface and help stay in English. Review transaction dates, amounts and notification status when testing.

Shortcuts provides Start Recording and Toggle Recording. For Back Tap, create a shortcut using Toggle Recording (or URL `mixcapture://toggle` followed by Open URLs), then select it in Settings > Accessibility > Touch > Back Tap. Unlock/foreground and microphone permission may be required. Local transcription is foreground-only, supports recordings up to 30 minutes, and does not guarantee every English word keeps Latin script.

Build 5 replaces the small model with the pinned 823 MB medium-Q8 model. It uses more memory and may take longer; real-device Metal memory, latency and accuracy remain acceptance checks. The shared money parser also recognizes the Arabic spelling of one hundred without dropping it from amounts.

## Build and verification

Requires Xcode/iOS SDK 26 or later on macOS. Public GitHub Actions builds without signing:

```
bash scripts/build-unsigned.sh
bash scripts/test-ui.sh
```

The pipeline runs Foundation model/money/state/parser checks, adversarial Arabic/English cases, a real Whisper smoke test against the public ArzEn sample (including repeatability, AAC conversion, silence and cancellation), a device build, and native simulator UI tests with screenshots. Synthetic UI fixtures exist only in Debug simulator builds with `--ui-testing`. No personal audio or data is in this repository or its artifacts. The public sample is evaluation-only and is not bundled.

The IPA is unsigned and requires signing through a sideloading tool. Real-device microphone, background behavior, notifications, EventKit permission and Back Tap still require device testing. Free developer provisioning requires periodic renewal. The bundled model and whisper.cpp licenses/attribution are in ThirdPartyNotices.txt.

## Build 6: transcription recovery

Mixed Whisper now shows its current stage and elapsed time and supports Stop transcription while preserving audio and any previous text. A cooperative whole-run budget of max(120 seconds, 12 times audio duration) yields a retryable terminal failure, without an automatic retry loop. Model loading and native Metal graphs cannot be forcibly interrupted; the app retains their context until they return. Backgrounding restarts the file from the beginning on return. The model and decoding parameters are unchanged; the cause of an individual slow run still needs real-device measurement.
