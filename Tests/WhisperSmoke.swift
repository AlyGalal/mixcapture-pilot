import AVFoundation
import Foundation
import Darwin

/// Runs the actual bundled model, not a mocked transcript. Inputs are public research/sample audio.
@main
struct WhisperSmoke {
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "WhisperSmoke", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: message]) }
        print("PASS \(message)")
    }

    static func hasBothScripts(_ text: String) -> Bool {
        text.range(of: "[A-Za-z]", options: .regularExpression) != nil &&
        text.range(of: "[\\u0621-\\u064A]", options: .regularExpression) != nil
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let audio = URL(fileURLWithPath: CommandLine.arguments[1])
        let aac = URL(fileURLWithPath: CommandLine.arguments[2])
        let first = try await LocalTranscriber.transcribe(audioURL: audio, locale: .mixedArabicEnglish)
        print("PUBLIC ARZEN SAMPLE: \(first.segments.joined(separator: " "))")
        try require(hasBothScripts(first.segments.joined(separator: " ")),
                    "public Egyptian Arabic/English example retains both scripts")
        let words = first.segments.joined(separator: " ").lowercased()
        try require(words.contains("network") && words.contains("project") && words.contains("يعني"),
                    "unprompted English network/project terms and Arabic يعني remain in their scripts")
        let again = try await LocalTranscriber.transcribe(audioURL: audio, locale: .mixedArabicEnglish)
        try require(first.segments == again.segments, "same PCM yields identical beam-search transcript on CI CPU")
        let compressed = try await LocalTranscriber.transcribe(audioURL: aac, locale: .mixedArabicEnglish)
        print("PUBLIC ARZEN AAC: \(compressed.segments.joined(separator: " "))")
        try require(hasBothScripts(compressed.segments.joined(separator: " ")),
                    "44.1-kHz stereo AAC conversion retains both scripts")

        let english = try await LocalTranscriber.transcribe(
            audioURL: URL(fileURLWithPath: CommandLine.arguments[3]), locale: .mixedArabicEnglish)
        let englishText = english.segments.joined(separator: " ")
        print("PUBLIC ENGLISH CONTROL: \(englishText)")
        try require(englishText.lowercased().contains("americans") && englishText.lowercased().contains("country") &&
                    englishText.range(of: "[\\u0621-\\u064A]", options: .regularExpression) == nil,
                    "English-only speech stays in English under the same mixed profile")

        let silence = audio.deletingLastPathComponent().appendingPathComponent("silence.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        do {
            let file = try AVAudioFile(forWriting: silence, settings: format.settings)
            try file.write(from: buffer)
        }
        var rejected = false
        do { _ = try await LocalTranscriber.transcribe(audioURL: silence, locale: .mixedArabicEnglish) }
        catch { rejected = true }
        try require(rejected, "silence never becomes invented glossary text")

        let cancelled = Task { try await LocalTranscriber.transcribe(audioURL: audio, locale: .mixedArabicEnglish) }
        cancelled.cancel()
        rejected = false
        do { _ = try await cancelled.value } catch is CancellationError { rejected = true }
        try require(rejected, "cancelled transcription cannot return a successful result")

        // Unlike the pre-cancel check above, stop AFTER whisper.cpp has entered its encoder.
        // Public research audio only. A failure must release the context so the next run works.
        let backgroundStop = WhisperTranscriber.CancelFlag()
        backgroundStop.cancel()
        backgroundStop.setTimeLimit(0)
        try require(backgroundStop.isCancelled && !backgroundStop.hasTimedOut,
                    "background cancellation remains cancellation after its deadline")
        let expiredFirst = WhisperTranscriber.CancelFlag()
        expiredFirst.setTimeLimit(0)
        expiredFirst.cancel()
        try require(expiredFirst.hasTimedOut, "deadline reached before cancellation remains timeout")
        let originalAudio = try Data(contentsOf: audio)
        for timeout in [false, true] {
            let control = WhisperTranscriber.CancelFlag()
            let running = Task {
                try await WhisperTranscriber.transcribe(audioURL: audio, control: control)
            }
            let waitStarted = ProcessInfo.processInfo.systemUptime
            while !control.hasEnteredNativeEncoder && ProcessInfo.processInfo.systemUptime - waitStarted < 45 {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard control.hasEnteredNativeEncoder else {
                running.cancel()
                _ = try? await running.value
                try require(false, "native encoder must be reached before the in-flight stop check")
                return
            }
            if timeout { control.setTimeLimit(0) } else { running.cancel() }
            rejected = false
            do { _ = try await running.value }
            catch is CancellationError { rejected = !timeout }
            catch WhisperTranscriber.Failure.timedOut { rejected = timeout }
            try require(rejected, timeout ? "in-flight timeout is terminal failure, not cancellation/requeue"
                                          : "in-flight native cancellation cannot return late text")
            try require(try Data(contentsOf: audio) == originalAudio, "in-flight stop keeps original audio unchanged")
        }
        let afterStop = try await LocalTranscriber.transcribe(audioURL: audio, locale: .mixedArabicEnglish)
        try require(afterStop.segments == first.segments, "manual retry works after native cancellation and timeout")
        print("Whisper smoke checks passed; one public sample does not establish real-device accuracy.")
    }
}
