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
        try require(first.segments == again.segments, "same PCM yields identical greedy transcript on CI CPU")
        let compressed = try await LocalTranscriber.transcribe(audioURL: aac, locale: .mixedArabicEnglish)
        print("PUBLIC ARZEN AAC: \(compressed.segments.joined(separator: " "))")
        try require(hasBothScripts(compressed.segments.joined(separator: " ")),
                    "44.1-kHz stereo AAC conversion retains both scripts")

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
        print("Whisper smoke checks passed; one public sample does not establish real-device accuracy.")
    }
}
