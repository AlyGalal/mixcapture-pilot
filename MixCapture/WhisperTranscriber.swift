import AVFoundation
import Foundation
import whisper

/// Fully offline multilingual Whisper (whisper.cpp + bundled ggml-small-q5_1.bin) for the `ar+en`
/// profile. A candidate for A/B comparison with DictationTranscriber, not a guarantee of anything.
/// No network, no download, no fallback to another engine. Output segments are returned verbatim:
/// no transliteration, translation, script normalization or text substitution.
///
/// whisper.cpp is not safe for concurrent use of one context, so every C call runs serially on this
/// actor's executor (never the main actor), with a fresh context per run that is freed in `defer`.
actor WhisperTranscriber {
    static let engineName = "Whisper.cpp 1.8.2 / small-q5_1 ae85e4a9 / multilingual / auto / greedy0"
    static let modelResource = "ggml-small-q5_1"
    private static let sampleRate = 16_000.0
    /// ponytail: 30 min cap (~115 MB of Float32), far below Int32.max samples; longer audio is
    /// rejected instead of silently truncated. Upgrade path: chunked inference.
    private static let maxSamples = 16_000 * 60 * 30
    private static let shared = WhisperTranscriber()

    static var modelURL: URL? {
        Bundle.main.url(forResource: modelResource, withExtension: "bin")
    }

    enum Failure: LocalizedError {
        case modelMissing
        case modelLoadFailed
        case notMultilingual
        case audioFormat(String)
        case audioTooLong(maxMinutes: Int)
        case inferenceFailed(code: Int32)

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                return "نموذج Whisper (ggml-small-q5_1.bin) غير موجود داخل التطبيق. لا يحدث أي تنزيل؛ الصوت محفوظ."
            case .modelLoadFailed:
                return "تعذر تحميل نموذج Whisper المضمّن. الصوت محفوظ ويمكن إعادة المحاولة."
            case .notMultilingual:
                return "النموذج المضمّن ليس multilingual؛ لن نستخدمه لملف ar+en. الصوت محفوظ."
            case .audioFormat(let detail):
                return "تعذر تحويل الصوت إلى 16 kHz mono لـWhisper: \(detail). الصوت الأصلي محفوظ."
            case .audioTooLong(let minutes):
                return "التسجيل أطول من \(minutes) دقيقة؛ لم نقصّه. الصوت الأصلي محفوظ."
            case .inferenceFailed(let code):
                return "فشل Whisper أثناء التفريغ (whisper_full = \(code)). الصوت الأصلي محفوظ."
            }
        }
    }

    /// Thread-safe cancel flag. Set from `withTaskCancellationHandler`, read by whisper.cpp's
    /// `abort_callback` on its compute threads.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// Transcribes one finalized recording. Throws `CancellationError` if cancelled at any point;
    /// a cancelled run never returns a result. The audio file is only read, never modified.
    static func transcribe(audioURL: URL, glossary: [String]) async throws -> LocalTranscriber.Output {
        let flag = CancelFlag()
        let output = try await withTaskCancellationHandler {
            try await shared.run(audioURL: audioURL, glossary: glossary, flag: flag)
        } onCancel: {
            flag.cancel()
        }
        try Task.checkCancellation()
        return output
    }

    private func run(audioURL: URL, glossary: [String], flag: CancelFlag) throws -> LocalTranscriber.Output {
        let isCancelled = { flag.isCancelled || Task.isCancelled }
        func checkCancelled() throws {
            if isCancelled() { throw CancellationError() }
        }

        guard let modelURL = Self.modelURL else { throw Failure.modelMissing }
        try checkCancelled()
        // Elapsed time covers audio conversion + model load + inference (the full user-visible wait).
        let started = ProcessInfo.processInfo.systemUptime
        let samples = try Self.decodeMono16k(audioURL, isCancelled: isCancelled)
        try checkCancelled()
        guard samples.contains(where: { $0.isFinite && abs($0) > 0.00001 }) else {
            throw LocalTranscriber.Failure.noSpeech
        }
        guard samples.count <= Self.maxSamples, let sampleCount = Int32(exactly: samples.count) else {
            throw Failure.audioTooLong(maxMinutes: Self.maxSamples / 16_000 / 60)
        }

        var contextParams = whisper_context_default_params()
#if targetEnvironment(simulator) || os(macOS)
        // The Mac command-line smoke check uses CPU; the iPhone build keeps Metal enabled.
        contextParams.use_gpu = false
#endif
        guard let context = whisper_init_from_file_with_params(modelURL.path(percentEncoded: false), contextParams) else {
            throw Failure.modelLoadFailed
        }
        defer { whisper_free(context) }
        guard whisper_is_multilingual(context) != 0 else { throw Failure.notMultilingual }
        try checkCancelled()

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.processorCount - 2)))
        params.translate = false
        // Auto: whisper_full picks the language itself. detect_language=true would only detect and stop.
        params.detect_language = false
        // Nothing from earlier recordings. This does not drop initial_prompt (see whisper.h).
        params.no_context = true
        params.temperature = 0
        params.temperature_inc = 0 // no temperature fallback: reproducible greedy decoding
        params.greedy.best_of = 1
        params.suppress_blank = true
        params.suppress_nst = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        // Native cancellation: whisper.cpp polls this before ggml computations; true = abort.
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<CancelFlag>.fromOpaque(userData).takeUnretainedValue().isCancelled
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(flag).toOpaque()

        // Initial prompt = existing English glossary words only (vocabulary bias, no instructions).
        let prompt = glossary.joined(separator: ", ")
        let code: Int32 = "auto".withCString { language -> Int32 in
            prompt.withCString { initialPrompt -> Int32 in
                // Both C strings and the flag stay alive for the whole synchronous whisper_full call.
                params.language = language
                params.initial_prompt = prompt.isEmpty ? nil : initialPrompt
                return withExtendedLifetime(flag) {
                    samples.withUnsafeBufferPointer { pcm in
                        whisper_full(context, params, pcm.baseAddress, sampleCount)
                    }
                }
            }
        }
        // An aborted or cancelled run is never reported as success, whatever whisper_full returned.
        try checkCancelled()
        guard code == 0 else { throw Failure.inferenceFailed(code: code) }

        var segments: [String] = []
        let segmentCount = whisper_full_n_segments(context)
        if segmentCount > 0 {
            for index in 0..<segmentCount {
                if let text = whisper_full_get_segment_text(context, index) {
                    segments.append(String(cString: text))
                }
            }
        }
        let languageID = whisper_full_lang_id(context)
        var language = "unknown"
        if languageID >= 0, let short = whisper_lang_str(languageID) {
            language = String(cString: short)
        }
        try checkCancelled()
        guard segments.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw LocalTranscriber.Failure.noSpeech
        }
        return LocalTranscriber.Output(segments: segments, resolvedLocale: language,
                                       engine: Self.engineName + (prompt.isEmpty ? "" : "+glossary-prompt"),
                                       elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
    }

    /// Converter pull state. AVAudioConverter calls the input block synchronously inside
    /// `convert(to:error:withInputFrom:)`, so this is only touched on the actor's thread.
    private final class ConverterInput: @unchecked Sendable {
        let file: AVAudioFile
        var finished = false
        var readError: Error?

        init(file: AVAudioFile) { self.file = file }
    }

    /// Decodes AAC/M4A/etc. to Float32, 16 kHz, mono, keeping exactly the frames the converter returns.
    private static func decodeMono16k(_ url: URL, isCancelled: () -> Bool) throws -> [Float] {
        let input = ConverterInput(file: try AVAudioFile(forReading: url))
        let inFormat = input.file.processingFormat
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw Failure.audioFormat("unsupported source format \(inFormat)")
        }
        converter.downmix = true
        let inChunk: AVAudioFrameCount = 8_192
        let outCapacity = AVAudioFrameCount((Double(inChunk) * sampleRate / inFormat.sampleRate).rounded(.up)) + 1_024
        var samples: [Float] = []
        samples.reserveCapacity(min(maxSamples, Int(Double(max(input.file.length, 0)) * sampleRate / inFormat.sampleRate) + 1_024))

        while true {
            if isCancelled() { throw CancellationError() }
            guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
                throw Failure.audioFormat("could not allocate output buffer")
            }
            var convertError: NSError?
            let status = converter.convert(to: output, error: &convertError) { requested, inputStatus in
                if input.finished || input.readError != nil {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let count = min(requested, inChunk)
                guard count > 0, input.file.framePosition < input.file.length,
                      let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: count) else {
                    input.finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.file.read(into: buffer, frameCount: count)
                } catch {
                    input.readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard buffer.frameLength > 0 else {
                    input.finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            // A read error mid-file fails the run rather than transcribing a truncated prefix.
            if let readError = input.readError { throw readError }
            if status == .error {
                throw convertError ?? Failure.audioFormat("AVAudioConverter error")
            }
            let produced = Int(output.frameLength)
            if produced > 0 {
                guard let channel = output.floatChannelData?[0] else {
                    throw Failure.audioFormat("converter returned no Float32 channel data")
                }
                guard samples.count + produced <= maxSamples else {
                    throw Failure.audioTooLong(maxMinutes: maxSamples / 16_000 / 60)
                }
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: produced))
            }
            if status == .endOfStream { break }
            if produced == 0 && input.finished { break } // never spin without progress
        }
        return samples
    }
}
