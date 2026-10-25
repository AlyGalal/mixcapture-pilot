import AVFoundation
import Foundation
import Observation
import UIKit

/// Single app state. Every start request (button, App Shortcut/Back Tap, URL) goes through
/// `requestStart()`, which only records while the scene is active and the mic is allowed.
@MainActor
@Observable
final class CaptureModel: NSObject, AVAudioPlayerDelegate, AVAudioRecorderDelegate {
    enum Status {
        case idle
        case waitingToStart
        case recording
        case processing
        case saved(String)
        case failed(String)
    }

    struct PrepareNote {
        let text: String
        let isError: Bool
    }

    static let shared = CaptureModel()
    /// A queued start (e.g. from Back Tap) that never reached the foreground expires,
    /// so the app does not start recording unexpectedly much later.
    private static let pendingStartLifetime: TimeInterval = 120

    var records: [CaptureRecord] = []
    var selectedLocale: PilotLocale = .mixedArabicEnglish
    var selectedCaseID: String? = TestCase.all.first?.id
    var assetReports: [PilotLocale: LocalTranscriber.AssetReport] = [:]
    var preparingLocale: PilotLocale?
    /// Last Apple Prepare outcome per locale, shown next to its button.
    var prepareNotes: [PilotLocale: PrepareNote] = [:]
    var playingID: UUID?
    var storageWarning: String?
    private(set) var activeRecord: CaptureRecord?
    private(set) var pendingStartAt: Date?
    private(set) var transcribingID: UUID?
    private var outcome: Status = .idle

    let deviceDescription: String
    let osDescription: String

    @ObservationIgnored private var store: CaptureStore?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored private var isRequestingPermission = false
    @ObservationIgnored private var isSceneActive = false
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    var status: Status {
        if activeRecord != nil { return .recording }
        if pendingStartAt != nil { return .waitingToStart }
        if transcribingID != nil { return .processing }
        return outcome
    }

    var isRecording: Bool { activeRecord != nil }
    var isWaitingToStart: Bool { pendingStartAt != nil }

    override init() {
        deviceDescription = Self.machineIdentifier()
        osDescription = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        super.init()
        do {
            let store = try CaptureStore.inDocuments()
            self.store = store
            let loaded = store.loadAll()
            var recovered = loaded.records
            for index in recovered.indices {
                if recovered[index].recoverAfterRelaunch() {
                    save(recovered[index], with: store)
                }
            }
            records = recovered
            if let error = loaded.errorMessage {
                storageWarning = "تعذرت قراءة مجلد التسجيلات؛ لم نحذف أي ملف: \(error)"
            }
            if !loaded.unreadableFiles.isEmpty {
                storageWarning = "تعذرت قراءة \(loaded.unreadableFiles.count) ملف JSON (لم يُحذف أي شيء): \(loaded.unreadableFiles.joined(separator: ", "))"
            }
        } catch {
            storageWarning = "تعذر فتح مجلد التسجيلات: \(error.localizedDescription)"
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(rawType: rawType) }
        }
    }

    // MARK: Scene

    func sceneChanged(isActive: Bool, isBackground: Bool) {
        isSceneActive = isActive
        if isActive {
            startIfPossible()
            processPendingTranscriptions()
            if assetReports.isEmpty { refreshAssetStatus() }
        } else if isBackground {
            // Heavy transcription is foreground-only; the capture stays pending and resumes on open.
            transcriptionTask?.cancel()
        }
    }

    // MARK: Recording

    func requestStart() {
        guard activeRecord == nil else { return } // duplicate start
        pendingStartAt = Date()
        startIfPossible()
    }

    func cancelPendingStart() {
        pendingStartAt = nil
    }

    private func startIfPossible() {
        guard let requestedAt = pendingStartAt, isSceneActive, !isRequestingPermission, activeRecord == nil else { return }
        guard Date().timeIntervalSince(requestedAt) < Self.pendingStartLifetime else {
            pendingStartAt = nil
            outcome = .failed("انتهت صلاحية طلب التسجيل المعلّق. اضغط ابدأ من جديد.")
            return
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .undetermined:
            isRequestingPermission = true
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                isRequestingPermission = false
                guard pendingStartAt != nil else { return }
                if granted {
                    pendingStartAt = Date() // time spent on the system prompt does not count
                    startIfPossible() // waits for .active again if the prompt left the scene inactive
                } else {
                    micDenied()
                }
            }
        case .denied:
            micDenied()
        @unknown default:
            micDenied()
        }
    }

    private func micDenied() {
        pendingStartAt = nil
        outcome = .failed("الوصول للميكروفون مرفوض. فعّله من Settings › Privacy & Security › Microphone.")
    }

    private func beginRecording() {
        pendingStartAt = nil
        guard let store else {
            outcome = .failed("لا يمكن التسجيل: مجلد التسجيلات غير متاح.")
            return
        }
        stopPlayback()
        transcriptionTask?.cancel() // capture takes priority over processing an earlier file
        var record = CaptureRecord(requestedLocale: selectedLocale.rawValue,
                                   testCase: TestCase.find(selectedCaseID),
                                   device: deviceDescription, osVersion: osDescription)
        let session = AVAudioSession.sharedInstance()
        var metadataSaved = false
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: store.audioURL(for: record), settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            recorder.delegate = self
            // Metadata first, so a capture cut off by a crash is still rediscovered on relaunch.
            try store.save(record)
            metadataSaved = true
            guard recorder.record() else {
                throw NSError(domain: "MixCapture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "AVAudioRecorder did not start"])
            }
            self.recorder = recorder
            activeRecord = record
            outcome = .idle
        } catch {
            if metadataSaved {
                record.fail("تعذر بدء التسجيل: \(error.localizedDescription)")
                upsert(record)
            }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            outcome = .failed("تعذر بدء التسجيل: \(error.localizedDescription)")
        }
    }

    func stopRecording(interrupted: Bool = false) {
        guard let recorder, var record = activeRecord else { return }
        let duration = recorder.currentTime
        recorder.stop() // finalizes the M4A so it stays playable even if transcription fails
        self.recorder = nil
        activeRecord = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        record.finishRecording(durationSeconds: duration, interrupted: interrupted)
        upsert(record)
        outcome = .saved(isSceneActive
            ? "حُفظ الصوت (saved)."
            : "حُفظ الصوت (saved). التفريغ يبدأ عند فتح التطبيق.")
        processPendingTranscriptions()
    }

    private func handleInterruption(rawType: UInt?) {
        guard let rawType, AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
        // Keep what was captured: finalize the file instead of losing it to the interruption.
        if activeRecord != nil { stopRecording(interrupted: true) }
        stopPlayback()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let finished = ObjectIdentifier(recorder)
        Task { @MainActor in
            guard let current = self.recorder, ObjectIdentifier(current) == finished else { return }
            self.stopRecording(interrupted: true)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let failed = ObjectIdentifier(recorder)
        let message = error?.localizedDescription ?? "Audio encoding failed"
        Task { @MainActor in
            guard let current = self.recorder, ObjectIdentifier(current) == failed else { return }
            self.stopRecording(interrupted: true)
            self.outcome = .failed("انقطع التسجيل: \(message). احتفظنا بملف الصوت لمحاولة استعادته.")
        }
    }

    // MARK: Transcription

    func retryTranscription(_ id: UUID) {
        guard records.first(where: { $0.id == id })?.canRetry == true else { return }
        let locale = selectedLocale.rawValue
        update(id) { $0.queueTranscription(locale: locale) }
        processPendingTranscriptions()
    }

    /// Runs pending captures one at a time, oldest first, only while the scene is active.
    private func processPendingTranscriptions() {
        guard isSceneActive, activeRecord == nil, pendingStartAt == nil, transcriptionTask == nil,
              let next = records.last(where: { $0.status == .pendingTranscription }) else { return }
        transcriptionTask = Task {
            await transcribe(next.id)
            transcriptionTask = nil
            processPendingTranscriptions()
        }
    }

    private func transcribe(_ id: UUID) async {
        guard let store, let record = records.first(where: { $0.id == id }) else { return }
        update(id) { $0.beginTranscription() }
        transcribingID = id
        defer { transcribingID = nil }
        let locale = PilotLocale(rawValue: record.requestedLocale) ?? .arabicEgypt
        do {
            let output = try await LocalTranscriber.transcribe(audioURL: store.audioURL(for: record), locale: locale)
            try Task.checkCancellation()
            update(id) {
                $0.finishTranscription(segments: output.segments, resolvedLocale: output.resolvedLocale,
                                       engine: output.engine, processingSeconds: output.elapsedSeconds)
            }
            outcome = .saved("اكتمل التفريغ المحلي في \(output.elapsedSeconds.formatted(.number.precision(.fractionLength(1)))) s.")
        } catch {
            if Task.isCancelled || error is CancellationError {
                update(id) { $0.deferTranscription() }
            } else {
                let message = error.localizedDescription
                update(id) { $0.fail(message) }
                outcome = .failed("فشل التفريغ: \(message)")
            }
        }
    }

    func setAssessment(_ assessment: ManualAssessment, for id: UUID) {
        update(id) { $0.assessment = assessment }
    }

    // MARK: Assets (explicit actions only)

    func refreshAssetStatus() {
        Task {
            for locale in PilotLocale.allCases {
                assetReports[locale] = await LocalTranscriber.assetReport(for: locale)
            }
        }
    }

    func prepare(_ locale: PilotLocale) {
        guard preparingLocale == nil else { return }
        preparingLocale = locale
        prepareNotes[locale] = nil
        Task {
            do {
                let report = try await LocalTranscriber.prepareAssets(for: locale)
                assetReports[locale] = report
                let message = "assets \(locale.rawValue) جاهزة للتفريغ المحلي (resolved \(report.resolved ?? "?"), \(report.status))."
                prepareNotes[locale] = PrepareNote(text: message, isError: false)
                outcome = .saved(message)
            } catch {
                let message = "تعذر تجهيز \(locale.rawValue): \(error.localizedDescription)"
                prepareNotes[locale] = PrepareNote(text: message, isError: true)
                outcome = .failed(message)
                assetReports[locale] = await LocalTranscriber.assetReport(for: locale)
            }
            preparingLocale = nil
        }
    }

    // MARK: Playback

    func togglePlayback(_ record: CaptureRecord) {
        if playingID == record.id {
            stopPlayback()
            return
        }
        guard !isRecording, let store else { return }
        stopPlayback()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: store.audioURL(for: record))
            player.delegate = self
            guard player.play() else {
                throw NSError(domain: "MixCapture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer did not start"])
            }
            self.player = player
            playingID = record.id
        } catch {
            outcome = .failed("تعذر تشغيل التسجيل: \(error.localizedDescription)")
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
        if activeRecord == nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            if let current = self.player, ObjectIdentifier(current) == finished {
                self.stopPlayback()
            }
        }
    }

    // MARK: Sharing (only from explicit share buttons)

    func resultsJSON() -> String {
        ResultsExport(records: records).jsonString()
    }

    func diagnosticJSON(for record: CaptureRecord) -> String {
        ResultsExport(records: [record]).jsonString()
    }

    // MARK: Persistence helpers

    private func upsert(_ record: CaptureRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        if let store { save(record, with: store) }
    }

    private func update(_ id: UUID, _ change: (inout CaptureRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        if let store { save(records[index], with: store) }
    }

    private func save(_ record: CaptureRecord, with store: CaptureStore) {
        do {
            try store.save(record)
        } catch {
            // In-memory state is kept; the audio file is untouched.
            storageWarning = "تعذر حفظ بيانات التسجيل \(record.id.uuidString): \(error.localizedDescription)"
        }
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
