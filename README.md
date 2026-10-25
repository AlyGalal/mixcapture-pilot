# MixCapture Pilot

A native iPhone voice-capture pilot with fully on-device Egyptian Arabic/English transcription, local expenses and local reminder notifications. iOS 26+. No cloud transcription, analytics or AI account.

## Mixed transcription (build 3)

The default Mixed Arabic+English profile uses whisper.cpp 1.8.2 and a bundled Egyptian/English fine-tuned Whisper Small Q8 model (~264 MB). It uses an Arabic language hint, beam search size 5, temperature zero, no earlier-recording context and no prompt. Text is retained verbatim; no translation or phonetic-word replacement is performed after recognition. The app performs no model download or audio upload in this path.

The model is Ibrahim Amin's Egyptian Arabic/English fine-tune, with ACFT adaptation and GGML Q8 conversion by AshrafMMahdy. Binary/model URLs are pinned and SHA-256 checked at build time. OpenAI/ggml MIT and upstream Apache-2.0 notices are included in the app. [Model provenance](https://huggingface.co/AshrafMMahdy/futo-egyptian-arabic-models/tree/0b4a13bc110d51207d971178c9bb054475cb3c62).

Apple DictationTranscriber Arabic/English remain manual comparison choices. Their Prepare buttons download Apple's assets explicitly. Successful same-audio retries preserve previous text, engine, locale, elapsed time and manual assessment in history and JSON export. Existing recordings remain readable. Whisper recordings over 30 minutes are rejected explicitly without modifying audio.

## Validation and limits

Run on macOS: `bash scripts/build-unsigned.sh`.

The build checks legacy persistence/history, money validation and reminders, then runs the actual model against the [public ArzEn authors' example](https://sites.google.com/view/arzen-corpus/resources). It checks Arabic/Latin anchor words, same-file repeatability on its CPU, 44.1-kHz stereo AAC conversion, silence and cancellation before compiling the iPhone app. Research audio is fetched for CI evaluation only; it is not committed, packaged or uploaded as an artifact.

ArzEn may overlap the fine-tune's training data. This is a functional regression check, not held-out accuracy evidence. Real-device code switching, English orthography, memory and latency still require representative phone recordings. Script preservation is not guaranteed.

## Install and Back Tap

The IPA is unsigned. Sign/install using a local sideloader such as [iloader](https://iloader.app/) with your own Apple account. Keep the existing app and use the same signing identity when updating to retain its data. Free developer signing requires periodic renewal; do not delete the app to refresh it.

After a manual recording works, save the app's Start Recording action as a personal Shortcut. Alternatively, use a URL action `mixcapture://record` followed by Open URLs. Select it under Settings > Accessibility > Touch > Back Tap.

Recording begins after the app enters the foreground and microphone permission is granted. Unlocking may be necessary. Ongoing file transcription runs in the foreground and is safely cancelled/deferred when backgrounded.

## Other local features

Expenses use integer minor units, user-selected categories and separate monthly totals per currency. Reminders use local notifications. Amounts, categories and dates require manual review/entry; automatic command extraction and Apple Calendar integration are not implemented.

Source and synthetic text fixtures only: do not submit personal audio, exported results, device identifiers or signing credentials to this repository.