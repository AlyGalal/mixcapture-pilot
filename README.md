# MixCapture Pilot

Experimental native iPhone app for on-device Arabic/English mixed speech transcription with bundled multilingual Whisper and Apple DictationTranscriber comparison profiles. iOS 26 or later. No Apple Intelligence requirement, cloud transcription, analytics or account login.

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

## Build 3 mixed-language candidate

Mixed Arabic+English uses whisper.cpp 1.8.2 and bundled multilingual small-q5_1 weights (~190 MB). The binary and weights are pinned and checksum-verified at build time; this path performs no runtime downloads or audio uploads. Auto language detection, transcription (no translation), greedy temperature 0 and a short glossary prompt are used. No phonetic text replacement is performed. Code switching/script preservation must be evaluated on representative device audio; it is not guaranteed.

Successful retries archive the previous exact transcript, engine, locale, elapsed time and manual rating. Legacy recordings remain readable. The build runs a real-model smoke against the public ArzEn example linked by its authors at https://sites.google.com/view/arzen-corpus/resources, repeats the same PCM, converts to 44.1-kHz stereo AAC, and checks silence/cancellation. Public research audio is downloaded for CI evaluation only, never committed or included in the IPA/artifacts. Passing this sample does not establish real-device accuracy or latency. Whisper recordings over 30 minutes are rejected explicitly without modifying audio.
