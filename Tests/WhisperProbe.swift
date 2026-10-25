import Foundation

/// Observation tool for selecting the model/profile. This is not the acceptance smoke gate.
@main
struct WhisperProbe {
    static func main() async {
        var report: [String: Any] = [
            "model": ProcessInfo.processInfo.environment["WHISPER_MODEL_PATH"] ?? "?",
            "prompt": ProcessInfo.processInfo.environment["WHISPER_PROBE_PROMPT"] ?? "on",
            "language": ProcessInfo.processInfo.environment["WHISPER_PROBE_LANGUAGE"] ?? "auto"
        ]
        do {
            let result = try await LocalTranscriber.transcribe(
                audioURL: URL(fileURLWithPath: CommandLine.arguments[1]), locale: .mixedArabicEnglish)
            report["detectedLanguage"] = result.resolvedLocale
            report["segments"] = result.segments
            report["elapsedSeconds"] = result.elapsedSeconds
        } catch {
            report["error"] = error.localizedDescription
        }
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(Data("PROBE ".utf8) + data + Data("\n".utf8))
    }
}
