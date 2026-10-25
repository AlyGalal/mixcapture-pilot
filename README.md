# MixCapture Pilot

Experimental native iPhone app for on-device Arabic/English mixed speech transcription with Apple's DictationTranscriber and SpeechAnalyzer. iOS 26 or later. No Apple Intelligence requirement, third-party dependencies, cloud transcription, analytics or account login.

The app keeps recordings locally, prepares language assets only from an explicit setup action, and includes twelve synthetic spoken prompts with manual assessment. An SDK build does not verify real-device recognition or lock-screen behavior.

## Build and install

GitHub Actions runs the Foundation-only persistence/model checks and builds an **unsigned** device IPA:

```sh
bash scripts/build-unsigned.sh
```

The IPA must be signed before installation. For a personal Windows-based trial, follow the [official AltStore Classic instructions](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows). Free-account installations require periodic refresh. This app never asks for an Apple account or signing credentials.

## Back Tap

Save the app's Start Recording action as a personal Shortcut. Alternatively, make a Shortcut containing URL `mixcapture://record` followed by Open URLs. Select it under Settings > Accessibility > Touch > Back Tap.

Recording starts only after the app is foregrounded and microphone permission is granted. Unlocking may be necessary. This pilot has no recording extension or background microphone wake-up workaround.

## Mixed-language trials

Prepare the Arabic language assets explicitly, then test airplane mode with Wi-Fi disabled. Compare the transcript with the spoken prompt and assess manually. Each transcriber uses one locale; Arabic support alone is not a guarantee of within-sentence Arabic/English accuracy.

Source and synthetic text fixtures only: do not submit personal audio, exported results, device identifiers or signing credentials to this repository.

## Local expenses and reminders

Monthly expenses use integer minor units, user-selected categories, and separate totals per currency. Reminders use local notifications. Amounts, categories and dates require manual review and entry; automatic command extraction and Apple Calendar integration are not implemented. No push service is required.
