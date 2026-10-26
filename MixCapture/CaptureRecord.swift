import Foundation

// Foundation-only models, persistence and built-in test prompts.
// Compiled into the app and into Tests/ModelChecks.swift, so no Apple UI/audio frameworks here.

/// Transcription profile stored on every capture; raw values are persisted, never rename them.
/// `ar+en` is a profile label for the bundled multilingual Whisper path (Arabic language hint
/// per recording), not a BCP 47 locale. ar-EG / en-US are single-locale Apple
/// DictationTranscriber runs kept for comparison.
enum PilotLocale: String, CaseIterable, Codable, Identifiable {
    case mixedArabicEnglish = "ar+en"
    case arabicEgypt = "ar-EG"
    case englishUS = "en-US"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mixedArabicEnglish: return "Mixed Arabic+English (Whisper)"
        case .arabicEgypt: return "Apple Arabic (ar-EG)"
        case .englishUS: return "Apple English (en-US)"
        }
    }
}

/// An earlier successful transcript of the same audio, archived when a newer successful run
/// replaced it, so engine/locale comparisons never erase results. Stored verbatim.
struct TranscriptSnapshot: Codable, Equatable {
    let segments: [String]
    let resolvedLocale: String?
    let engine: String?
    let processingSeconds: Double?
    let manualAssessment: ManualAssessment

    var text: String { segments.joined(separator: " ") }
}

enum CaptureStatus: String, Codable {
    /// Audio file is open. Seen at launch only if the app ended mid-recording.
    case recording
    /// The app ended during recording; the audio may be incomplete or unplayable.
    case interrupted
    /// Audio finalized; transcription runs only while the app is in the foreground.
    case pendingTranscription
    case transcribing
    case transcribed
    case failed
}

/// Manual judgement only. The pilot never computes an automatic score.
enum ManualAssessment: String, Codable, CaseIterable {
    case unassessed
    case correct
    case needsWork
}

struct TestCase: Identifiable, Hashable {
    /// Stable lowercase ID, stored with every recording; never rename an existing one.
    let id: String
    let prompt: String
    /// What the prompt probes (shown under the prompt).
    let focus: String

    static func find(_ id: String?) -> TestCase? {
        all.first { $0.id == id }
    }

    static let all: [TestCase] = [
        TestCase(id: "review-budget-home",
                 prompt: "ضيف review الـbudget لمشروع Home وفكرني بيه بكرة 10 AM",
                 focus: "English nouns inside Arabic + الـ prefix + time"),
        TestCase(id: "groceries-milk-yogurt",
                 prompt: "Add milk وعلبتين yogurt لقائمة Groceries",
                 focus: "English start, Arabic dual quantity"),
        TestCase(id: "design-meeting-thursday",
                 prompt: "حط design meeting الخميس 3 PM لمدة thirty minutes",
                 focus: "Arabic weekday + English duration words"),
        TestCase(id: "correction-friday-thursday",
                 prompt: "مش Friday، خليها Thursday",
                 focus: "Spoken correction"),
        TestCase(id: "digits-arabic-indic",
                 prompt: "اعمل call مع المهندس الساعة ٤:٣٠ يوم ١٢",
                 focus: "Arabic-Indic digits"),
        TestCase(id: "digits-western",
                 prompt: "اعمل call مع المهندس الساعة 4:30 يوم 12",
                 focus: "Western digits, same sentence"),
        TestCase(id: "ambiguous-five-oclock",
                 prompt: "فكرني الساعة خمسة",
                 focus: "Ambiguous AM/PM (transcription only, no action)"),
        TestCase(id: "travel-flight-sunday",
                 prompt: "احجز flight لمشروع Travel يوم Sunday الصبح",
                 focus: "Project name + English weekday"),
        TestCase(id: "invoice-english-first",
                 prompt: "Remind me to send the invoice قبل الساعة تلاتة",
                 focus: "Mostly English, Arabic ending"),
        TestCase(id: "review-design-self-correction",
                 prompt: "غير الـreview من design لـbudget، لا استنى، خليها design",
                 focus: "Mid-sentence self-correction"),
        TestCase(id: "expense-groceries-egp",
                 prompt: "سجل مصروف groceries بقيمة ٣٥٠ جنيه للشهر ده",
                 focus: "Expense category + Arabic amount + currency (review manually)"),
        TestCase(id: "expense-transport-mixed",
                 prompt: "دفعت 120.50 EGP في Uber، التصنيف transport",
                 focus: "Mixed expense amount, service name and category"),
    ]
}

struct CaptureRecord: Codable, Identifiable, Equatable {
    let id: UUID
    /// Original recording time; never changed by retries.
    let recordedAt: Date
    let audioFileName: String
    /// Locale asked for on the latest (or next) transcription run.
    var requestedLocale: String
    /// Locale the engine resolved on the last successful run.
    var resolvedLocale: String?
    var engine: String?
    var testCaseID: String?
    var testPrompt: String?
    var durationSeconds: Double
    var status: CaptureStatus
    var wasInterrupted: Bool
    /// Final results exactly as the engine returned them (no normalization/translation).
    var transcriptSegments: [String]?
    /// Previous successful results, oldest first. Optional so JSON written before build 3 decodes.
    var transcriptHistory: [TranscriptSnapshot]?
    /// Nil for legacy recordings: upgrading never posts old test clips as real actions.
    var organizationEligible: Bool?
    var errorMessage: String?
    var processingSeconds: Double?
    var assessment: ManualAssessment
    var device: String
    var osVersion: String

    init(id: UUID = UUID(), recordedAt: Date = Date(), requestedLocale: String,
         testCase: TestCase?, device: String, osVersion: String) {
        self.id = id
        self.recordedAt = recordedAt
        self.audioFileName = "\(id.uuidString).m4a"
        self.requestedLocale = requestedLocale
        self.testCaseID = testCase?.id
        self.testPrompt = testCase?.prompt
        self.durationSeconds = 0
        self.status = .recording
        self.wasInterrupted = false
        self.assessment = .unassessed
        self.device = device
        self.osVersion = osVersion
        self.organizationEligible = testCase == nil
    }

    /// Display text. ponytail: segments are joined with one space for display/export;
    /// the exact engine segments stay in `transcriptSegments`.
    var transcript: String? {
        transcriptSegments?.joined(separator: " ")
    }

    var canRetry: Bool {
        status != .recording && status != .transcribing
    }

    mutating func finishRecording(durationSeconds: Double, interrupted: Bool) {
        self.durationSeconds = durationSeconds
        wasInterrupted = interrupted
        status = .pendingTranscription
    }

    /// Retry (possibly with a different locale/engine). The current transcript stays until a new
    /// successful run replaces it; it is then archived in `transcriptHistory`, never dropped.
    mutating func queueTranscription(locale: String) {
        requestedLocale = locale
        status = .pendingTranscription
    }

    mutating func beginTranscription() {
        status = .transcribing
        errorMessage = nil
    }

    /// Backgrounded/cancelled: keep the capture pending for the next foreground run.
    mutating func deferTranscription() {
        status = .pendingTranscription
    }

    mutating func finishTranscription(segments: [String], resolvedLocale: String,
                                      engine: String, processingSeconds: Double) {
        if let previous = transcriptSegments {
            // Archive the replaced success once, with its own metadata and manual rating.
            transcriptHistory = (transcriptHistory ?? []) + [
                TranscriptSnapshot(segments: previous, resolvedLocale: self.resolvedLocale, engine: self.engine,
                                   processingSeconds: self.processingSeconds, manualAssessment: assessment),
            ]
        }
        if segments != transcriptSegments {
            assessment = .unassessed // a new transcript needs a new manual judgement
        }
        transcriptSegments = segments
        self.resolvedLocale = resolvedLocale
        self.engine = engine
        self.processingSeconds = processingSeconds
        errorMessage = nil
        status = .transcribed
    }

    /// Audio and any earlier transcript are preserved; only the status and message change.
    mutating func fail(_ message: String) {
        errorMessage = message
        status = .failed
    }

    /// Normalizes states that cannot be live after a fresh launch. Returns true if changed.
    mutating func recoverAfterRelaunch() -> Bool {
        switch status {
        case .recording:
            status = .interrupted
            wasInterrupted = true
            errorMessage = "The app closed while recording. The audio file may be incomplete or unplayable."
            return true
        case .transcribing:
            status = .pendingTranscription
            return true
        case .interrupted, .pendingTranscription, .transcribed, .failed:
            return false
        }
    }
}

/// `<uuid>.m4a` + `<uuid>.json` pairs in one directory that is excluded from OS backup.
struct CaptureStore {
    let directory: URL

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        try Self.excludeFromBackup(&dir)
        self.directory = directory
    }

    static func inDocuments() throws -> CaptureStore {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        return try CaptureStore(directory: documents.appendingPathComponent("Captures", isDirectory: true))
    }

    func audioURL(for record: CaptureRecord) -> URL {
        directory.appendingPathComponent(record.audioFileName)
    }

    func metadataURL(for record: CaptureRecord) -> URL {
        directory.appendingPathComponent("\(record.id.uuidString).json")
    }

    /// Atomic write: a crash leaves either the old or the new JSON, never a torn file.
    func save(_ record: CaptureRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var url = metadataURL(for: record)
        try encoder.encode(record).write(to: url, options: .atomic)
        try Self.excludeFromBackup(&url)
    }

    /// Newest first. Unreadable files are reported and left on disk untouched.
    func loadAll() -> (records: [CaptureRecord], unreadableFiles: [String], errorMessage: String?) {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            return ([], [], error.localizedDescription)
        }
        var records: [CaptureRecord] = []
        var unreadable: [String] = []
        for file in files where file.pathExtension == "json" {
            do {
                records.append(try JSONDecoder().decode(CaptureRecord.self, from: Data(contentsOf: file)))
            } catch {
                unreadable.append(file.lastPathComponent)
            }
        }
        return (records.sorted { $0.recordedAt > $1.recordedAt }, unreadable.sorted(), nil)
    }

    static func excludeFromBackup(_ url: inout URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

/// Shared only when the user taps a share button. Manual assessment only; no computed score.
struct ResultsExport: Codable {
    struct Row: Codable {
        let captureID: UUID
        let recordedAt: Date
        let caseID: String?
        let prompt: String?
        let requestedLocale: String
        let resolvedLocale: String?
        let textIsPreviousResult: Bool
        let engine: String?
        let text: String?
        let segments: [String]?
        /// Earlier successful results of the same audio (oldest first), each with its own metadata.
        let previousResults: [TranscriptSnapshot]
        let elapsedSeconds: Double?
        let durationSeconds: Double
        let manualAssessment: ManualAssessment
        let status: CaptureStatus
        let error: String?
        let wasInterrupted: Bool
        let device: String
        let osVersion: String
    }

    let exportedAt: Date
    let app: String
    let note: String
    let results: [Row]

    init(records: [CaptureRecord], exportedAt: Date = Date()) {
        self.exportedAt = exportedAt
        app = "MixCapture 1.0 (4)"
        note = "Local transcription; manual assessment only. Engine, resolvedLocale and elapsedSeconds describe the retained transcript; textIsPreviousResult marks a result from an earlier successful attempt. previousResults lists earlier successful results of the same audio that a later run replaced. requestedLocale ar+en is a profile label (multilingual Whisper, Arabic language hint), not a BCP 47 locale."
        results = records.map { record in
            Row(captureID: record.id,
                recordedAt: record.recordedAt,
                caseID: record.testCaseID,
                prompt: record.testPrompt,
                requestedLocale: record.requestedLocale,
                resolvedLocale: record.resolvedLocale,
                textIsPreviousResult: record.transcriptSegments != nil && record.status != .transcribed,
                engine: record.engine,
                text: record.transcript,
                segments: record.transcriptSegments,
                previousResults: record.transcriptHistory ?? [],
                elapsedSeconds: record.processingSeconds,
                durationSeconds: record.durationSeconds,
                manualAssessment: record.assessment,
                status: record.status,
                error: record.errorMessage,
                wasInterrupted: record.wasInterrupted,
                device: record.device,
                osVersion: record.osVersion)
        }
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    func jsonString() -> String {
        do {
            return String(decoding: try jsonData(), as: UTF8.self)
        } catch {
            return "{\"error\":\"Could not encode results\"}"
        }
    }
}
