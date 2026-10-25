import AVFoundation
import Foundation
import Speech

/// On-device transcription with SpeechAnalyzer + DictationTranscriber (works on devices
/// without Apple Intelligence). Never downloads on its own and never uses network recognition:
/// assets are installed only by `prepareAssets`, which runs from an explicit user tap.
/// The `ar+en` profile goes to the bundled offline `WhisperTranscriber` instead; the Apple path
/// below is unchanged and never used as a silent fallback for it (or vice versa).
enum LocalTranscriber {
    static let engineName = "DictationTranscriber.longDictation"
    /// Small contextual-strings glossary. Biases recognition only; stored text is never rewritten.
    static let glossary = ["Home", "Travel", "budget", "review", "design", "Groceries"]

    /// Engine that will run for a profile (shown in the UI Engine row).
    static func engineLabel(for choice: PilotLocale) -> String {
        choice == .mixedArabicEnglish ? WhisperTranscriber.engineName : "\(engineName) (\(choice.rawValue))"
    }

    struct AssetReport: Sendable, Equatable {
        let requested: String
        let resolved: String?
        let status: String
    }

    struct Output: Sendable {
        let segments: [String]
        let resolvedLocale: String
        let engine: String
        let elapsedSeconds: Double
    }

    enum Failure: LocalizedError {
        case unsupportedLocale(String)
        case assetsNotInstalled(locale: String, status: String)
        case installIncomplete(locale: String, status: String)
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let locale):
                return "الـlocale \(locale) غير مدعومة في DictationTranscriber على هذا الجهاز."
            case .assetsNotInstalled(let locale, let status):
                return "assets التفريغ المحلي لـ\(locale) غير مثبتة (\(status)). اضغط Prepare أولاً؛ لا يحدث أي تنزيل تلقائي. الصوت محفوظ."
            case .installIncomplete(let locale, let status):
                return "انتهى Prepare لكن حالة assets لـ\(locale) هي \(status)."
            case .noSpeech:
                return "لم يُرجع المحرك أي نص (no speech). الصوت الأصلي محفوظ ويمكن إعادة المحاولة."
            }
        }
    }

    private static func resolve(_ choice: PilotLocale) async -> (module: DictationTranscriber, locale: Locale)? {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: choice.rawValue)) else {
            return nil
        }
        return (DictationTranscriber(locale: locale, preset: .longDictation), locale)
    }

    private static func describe(_ status: AssetInventory.Status) -> String {
        switch status {
        case .installed: return "installed"
        case .downloading: return "downloading"
        case .supported: return "not downloaded"
        case .unsupported: return "unsupported"
        @unknown default: return "unknown"
        }
    }

    /// Bundled Whisper model readiness. Read-only; there is nothing to download.
    private static func whisperReport() -> AssetReport {
        AssetReport(requested: PilotLocale.mixedArabicEnglish.rawValue, resolved: "multilingual",
                    status: WhisperTranscriber.modelURL == nil ? "model missing" : "installed")
    }

    /// Read-only status check; safe to call on launch.
    static func assetReport(for choice: PilotLocale) async -> AssetReport {
        if choice == .mixedArabicEnglish { return whisperReport() }
        guard let resolved = await resolve(choice) else {
            return AssetReport(requested: choice.rawValue, resolved: nil, status: "unsupported")
        }
        let status = await AssetInventory.status(forModules: [resolved.module])
        return AssetReport(requested: choice.rawValue, resolved: resolved.locale.identifier(.bcp47),
                           status: describe(status))
    }

    /// Explicit user action only: downloads/installs the on-device assets for one locale.
    static func prepareAssets(for choice: PilotLocale) async throws -> AssetReport {
        if choice == .mixedArabicEnglish {
            // The Whisper model ships inside the app; report it, never pretend to download it.
            let report = whisperReport()
            guard WhisperTranscriber.modelURL != nil else { throw WhisperTranscriber.Failure.modelMissing }
            return report
        }
        guard let resolved = await resolve(choice) else {
            throw Failure.unsupportedLocale(choice.rawValue)
        }
        // ponytail: no progress bar; the UI shows an indeterminate spinner. Upgrade path:
        // observe request.progress.fractionCompleted.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [resolved.module]) {
            try await request.downloadAndInstall()
        }
        var status = await AssetInventory.status(forModules: [resolved.module])
        if case .supported = status {
            // Assets can be on disk while this app's locale reservation was dropped;
            // reserving again restores .installed without a download.
            let tag = resolved.locale.identifier(.bcp47)
            if await DictationTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == tag }) {
                _ = try await AssetInventory.reserve(locale: resolved.locale)
                status = await AssetInventory.status(forModules: [resolved.module])
            }
        }
        let report = AssetReport(requested: choice.rawValue, resolved: resolved.locale.identifier(.bcp47),
                                 status: describe(status))
        guard case .installed = status else {
            throw Failure.installIncomplete(locale: report.resolved ?? choice.rawValue, status: report.status)
        }
        return report
    }

    /// Transcribes a finalized audio file with one locale and returns the final results verbatim.
    static func transcribe(audioURL: URL, locale choice: PilotLocale) async throws -> Output {
        if choice == .mixedArabicEnglish {
            return try await WhisperTranscriber.transcribe(audioURL: audioURL)
        }
        guard let resolved = await resolve(choice) else {
            throw Failure.unsupportedLocale(choice.rawValue)
        }
        let module = resolved.module
        let status = await AssetInventory.status(forModules: [module])
        guard case .installed = status else {
            throw Failure.assetsNotInstalled(locale: resolved.locale.identifier(.bcp47), status: describe(status))
        }
        let audioFile = try AVAudioFile(forReading: audioURL)
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        let analyzer = SpeechAnalyzer(modules: [module])

        var engine = engineName
        let context = AnalysisContext()
        context.contextualStrings[.general] = glossary
        do {
            try await analyzer.setContext(context)
            engine += "+glossary"
        } catch {
            // Glossary is optional; the engine string records that it was not applied.
        }

        let collector = Task { () throws -> [String] in
            var segments: [String] = []
            for try await result in module.results where result.isFinal {
                segments.append(String(result.text.characters))
            }
            return segments
        }

        let segments = try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                guard let lastSample = try await analyzer.analyzeSequence(from: audioFile) else {
                    throw Failure.noSpeech
                }
                // SpeechAnalyzer may return a consumed time when cancelled instead of throwing.
                try Task.checkCancellation()
                try await analyzer.finalizeAndFinish(through: lastSample)
                let collected = try await collector.value
                try Task.checkCancellation()
                return collected
            } catch {
                await analyzer.cancelAndFinishNow()
                collector.cancel()
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        guard segments.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw Failure.noSpeech
        }
        return Output(segments: segments, resolvedLocale: resolved.locale.identifier(.bcp47),
                      engine: engine, elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
    }
}
