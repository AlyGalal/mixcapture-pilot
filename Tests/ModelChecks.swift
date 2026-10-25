import Foundation

// Foundation-only checks for MixCapture/CaptureRecord.swift (no XCTest, no Apple UI SDK).
//   mkdir -p build && swiftc MixCapture/CaptureRecord.swift Tests/ModelChecks.swift -o build/model-checks && build/model-checks

@main
struct ModelChecks {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS \(message)" : "FAIL \(message)")
        if !condition { failures += 1 }
    }

    static func main() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixcapture-checks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try CaptureStore(directory: dir)

        // Built-in test cases: 8-12, unique stable lowercase IDs, non-empty prompts.
        let ids = TestCase.all.map(\.id)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        check((8...12).contains(ids.count), "8-12 built-in test cases (\(ids.count))")
        check(Set(ids).count == ids.count, "test case IDs are unique")
        check(ids.allSatisfy { !$0.isEmpty && $0.allSatisfy(allowed.contains) }, "test case IDs are stable lowercase-hyphen")
        check(TestCase.all.allSatisfy { !$0.prompt.isEmpty }, "every test case has a prompt")

        // Metadata roundtrip keeps mixed Arabic+English exactly.
        let mixed = "ضيف review الـbudget لمشروع Home وفكرني بيه بكرة 10 AM"
        var record = CaptureRecord(recordedAt: Date(timeIntervalSince1970: 1_800_001_000),
                                   requestedLocale: "ar-EG", testCase: TestCase.find("review-budget-home"),
                                   device: "iPhone14,3", osVersion: "iOS 27.0.1")
        check(record.status == .recording, "new capture starts in recording state")
        record.finishRecording(durationSeconds: 4.25, interrupted: false)
        check(record.status == .pendingTranscription, "stopped capture waits for transcription")
        record.beginTranscription()
        record.finishTranscription(segments: [mixed], resolvedLocale: "ar-EG",
                                   engine: "DictationTranscriber.longDictation+glossary", processingSeconds: 1.5)
        try store.save(record)
        let first = store.loadAll()
        check(first.records.count == 1 && first.unreadableFiles.isEmpty, "one record persisted")
        check(first.records.first == record, "metadata roundtrip is lossless")
        check(first.records.first?.transcript.map { Array($0.unicodeScalars) } == Array(mixed.unicodeScalars),
              "mixed Arabic+English text preserved scalar-for-scalar")
        check(first.records.first?.testCaseID == "review-budget-home"
              && first.records.first?.testPrompt == TestCase.find("review-budget-home")?.prompt,
              "test case ID and prompt attached")

        // Failure keeps audio + metadata; retry updates the same record in place.
        var retried = CaptureRecord(recordedAt: Date(timeIntervalSince1970: 1_700_000_000), requestedLocale: "ar-EG",
                                    testCase: TestCase.find("groceries-milk-yogurt"),
                                    device: "iPhone14,3", osVersion: "iOS 27.0.1")
        retried.finishRecording(durationSeconds: 3, interrupted: true)
        retried.beginTranscription()
        retried.fail("no speech")
        try store.save(retried)
        let failed = store.loadAll().records.first { $0.id == retried.id }
        check(failed?.status == .failed && failed?.errorMessage == "no speech" && failed?.wasInterrupted == true,
              "failed transcription persisted with error and interruption flag")
        check(failed?.canRetry == true, "failed capture can be retried")

        let originalAudio = retried.audioFileName
        retried.queueTranscription(locale: "en-US")
        check(retried.status == .pendingTranscription && retried.requestedLocale == "en-US", "retry queues with new locale")
        retried.beginTranscription()
        check(retried.errorMessage == nil && !retried.canRetry, "running transcription clears error and blocks retry")
        retried.finishTranscription(segments: ["Add milk وعلبتين yogurt لقائمة Groceries"], resolvedLocale: "en-US",
                                    engine: "DictationTranscriber.longDictation", processingSeconds: 0.8)
        retried.assessment = .needsWork
        try store.save(retried)
        let after = store.loadAll()
        let updated = after.records.first { $0.id == retried.id }
        check(after.records.count == 2, "retry overwrote the record (no duplicate)")
        check(updated?.status == .transcribed && updated?.errorMessage == nil, "retry result persisted")
        check(updated?.recordedAt == Date(timeIntervalSince1970: 1_700_000_000) && updated?.audioFileName == originalAudio,
              "original recording time and audio file kept across retry")
        check(updated?.assessment == .needsWork, "manual assessment persisted")
        check(after.records.first?.id == record.id, "records sorted newest first")

        // Failure after success keeps the earlier transcript.
        var keep = record
        keep.queueTranscription(locale: "en-US")
        keep.beginTranscription()
        keep.fail("engine error")
        check(keep.transcriptSegments == [mixed] && keep.status == .failed, "failed retry does not erase earlier transcript")
        let comparison = ResultsExport(records: [keep]).results[0]
        check(comparison.requestedLocale == "en-US" && comparison.resolvedLocale == "ar-EG"
              && comparison.textIsPreviousResult && comparison.text == mixed,
              "failed comparison identifies requested locale and earlier transcript separately")

        // Relaunch recovery.
        var killedWhileRecording = CaptureRecord(requestedLocale: "ar-EG", testCase: nil, device: "d", osVersion: "o")
        check(killedWhileRecording.recoverAfterRelaunch() && killedWhileRecording.status == .interrupted
              && killedWhileRecording.wasInterrupted && killedWhileRecording.errorMessage != nil,
              "capture left in recording state becomes interrupted")
        var killedWhileTranscribing = killedWhileRecording
        killedWhileTranscribing.finishRecording(durationSeconds: 1, interrupted: false)
        killedWhileTranscribing.beginTranscription()
        check(killedWhileTranscribing.recoverAfterRelaunch() && killedWhileTranscribing.status == .pendingTranscription,
              "capture left transcribing becomes pending again")
        var settled = record
        check(!settled.recoverAfterRelaunch(), "finished capture is untouched on relaunch")

        // Unreadable metadata is reported, never deleted.
        let corrupt = dir.appendingPathComponent("not-a-record.json")
        try Data("{".utf8).write(to: corrupt)
        let withCorrupt = store.loadAll()
        check(withCorrupt.records.count == 2 && withCorrupt.unreadableFiles == ["not-a-record.json"],
              "corrupt JSON reported, valid records still load")
        check(FileManager.default.fileExists(atPath: corrupt.path), "corrupt JSON left on disk")

        let unavailableDirectory = dir.appendingPathComponent("unavailable", isDirectory: true)
        let unavailableStore = try CaptureStore(directory: unavailableDirectory)
        try FileManager.default.removeItem(at: unavailableDirectory)
        check(unavailableStore.loadAll().errorMessage != nil,
              "unavailable directory is reported, not silently treated as an empty library")

        // Backup exclusion.
        let dirValues = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        let fileValues = try store.metadataURL(for: record).resourceValues(forKeys: [.isExcludedFromBackupKey])
        check(dirValues.isExcludedFromBackup == true && fileValues.isExcludedFromBackup == true,
              "captures directory and metadata excluded from backup")

        // Export: required fields, verbatim text, manual assessment only.
        let data = try ResultsExport(records: after.records).jsonData()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = json?["results"] as? [[String: Any]] ?? []
        let required = ["captureID", "recordedAt", "caseID", "requestedLocale", "resolvedLocale", "textIsPreviousResult", "engine", "text", "elapsedSeconds", "manualAssessment"]
        check(rows.count == 2, "export has one row per capture")
        check(rows.allSatisfy { row in required.allSatisfy { row[$0] != nil } }, "export rows contain required fields")
        check(rows.contains { $0["text"] as? String == mixed }, "export text is verbatim")
        check(rows.contains { $0["manualAssessment"] as? String == "needsWork" }, "export carries manual assessment")
        check(!String(decoding: data, as: UTF8.self).lowercased().contains("accuracy"), "no generated accuracy field")

        try historyChecks(dir: dir)

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("All model checks passed")
    }

    static func scalars(_ segments: [String]?) -> [[Unicode.Scalar]]? {
        segments?.map { Array($0.unicodeScalars) }
    }

    /// Build 3: same-audio engine comparison keeps earlier results; old JSON still decodes.
    /// Texts below are arbitrary stored fixtures, not ASR expectations; no accuracy is asserted.
    static func historyChecks(dir: URL) throws {
        check(PilotLocale.arabicEgypt.rawValue == "ar-EG" && PilotLocale.englishUS.rawValue == "en-US"
              && PilotLocale.mixedArabicEnglish.rawValue == "ar+en" && PilotLocale.allCases.count == 3,
              "profile raw values: ar-EG/en-US unchanged, ar+en added")
        check(PilotLocale(rawValue: "ar-EG") == .arabicEgypt && PilotLocale(rawValue: "en-US") == .englishUS
              && PilotLocale(rawValue: "ar+en") == .mixedArabicEnglish,
              "stored requestedLocale strings map back to profiles")

        // JSON as written by build 2: no transcriptHistory key.
        let appleEngine = "DictationTranscriber.longDictation+glossary"
        let legacyText = "مش فرايداي، خليها Thursday"
        let legacyJSON = """
        {
          "assessment" : "correct",
          "audioFileName" : "6F9619FF-8B86-D011-B42D-00C04FC964FF.m4a",
          "device" : "iPhone14,3",
          "durationSeconds" : 2.5,
          "engine" : "DictationTranscriber.longDictation+glossary",
          "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF",
          "osVersion" : "iOS 27.0.1",
          "processingSeconds" : 1.25,
          "recordedAt" : 800000000,
          "requestedLocale" : "ar-EG",
          "resolvedLocale" : "ar-SA",
          "status" : "transcribed",
          "testCaseID" : "correction-friday-thursday",
          "testPrompt" : "مش Friday، خليها Thursday",
          "transcriptSegments" : ["\(legacyText)"],
          "wasInterrupted" : false
        }
        """
        let legacy = try JSONDecoder().decode(CaptureRecord.self, from: Data(legacyJSON.utf8))
        check(legacy.transcriptHistory == nil && legacy.status == .transcribed && legacy.assessment == .correct,
              "legacy JSON without history decodes")
        check(legacy.requestedLocale == "ar-EG" && legacy.resolvedLocale == "ar-SA" && legacy.engine == appleEngine,
              "legacy locale and engine metadata decode unchanged")
        check(scalars(legacy.transcriptSegments) == scalars([legacyText]), "legacy transcript decoded scalar-for-scalar")
        var settledLegacy = legacy
        check(!settledLegacy.recoverAfterRelaunch() && settledLegacy == legacy,
              "completed legacy capture is not re-queued on launch")
        check(!String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self).contains("transcriptHistory"),
              "record without history writes no history key")

        // Same audio: Apple result, then Whisper result, then a failed and a cancelled retry.
        let whisperEngine = "Whisper small-q5_1 / multilingual / auto / greedy0+glossary-prompt"
        let appleSegments = ["ضيف ريفيو الـbudget لمشروع Home وفكرني بيه بكرة 10 AM"]
        let whisperSegments = [" ضيف review البادجت لمشروع Home", " وفكرني بيه بكرة 10 AM"]
        var compare = CaptureRecord(recordedAt: Date(timeIntervalSince1970: 1_800_002_000), requestedLocale: "ar-EG",
                                    testCase: TestCase.find("review-budget-home"),
                                    device: "iPhone14,3", osVersion: "iOS 27.0.1")
        let compareID = compare.id
        let compareAudio = compare.audioFileName
        compare.finishRecording(durationSeconds: 5, interrupted: false)
        compare.beginTranscription()
        compare.finishTranscription(segments: appleSegments, resolvedLocale: "ar-SA",
                                    engine: appleEngine, processingSeconds: 1.25)
        check(compare.transcriptHistory == nil, "first success archives nothing")
        compare.assessment = .needsWork

        compare.queueTranscription(locale: PilotLocale.mixedArabicEnglish.rawValue)
        compare.beginTranscription()
        check(compare.transcriptHistory == nil && scalars(compare.transcriptSegments) == scalars(appleSegments),
              "starting a comparison run does not touch the current result")
        compare.finishTranscription(segments: whisperSegments, resolvedLocale: "ar",
                                    engine: whisperEngine, processingSeconds: 6.5)
        let archived = compare.transcriptHistory ?? []
        let firstArchived = archived.first
        check(archived.count == 1, "replaced success archived exactly once")
        check(scalars(firstArchived?.segments) == scalars(appleSegments),
              "archived Apple result kept scalar-for-scalar")
        check(firstArchived?.engine == appleEngine && firstArchived?.resolvedLocale == "ar-SA",
              "archived result keeps engine and locale")
        check(firstArchived?.processingSeconds == 1.25 && firstArchived?.manualAssessment == .needsWork,
              "archived result keeps processing time and manual rating")
        check(scalars(compare.transcriptSegments) == scalars(whisperSegments) && compare.engine == whisperEngine,
              "new Whisper result is current")
        check(compare.resolvedLocale == "ar" && compare.requestedLocale == "ar+en",
              "current result carries its own requested/resolved locale")
        check(compare.assessment == .unassessed && compare.status == .transcribed,
              "new text needs a new manual rating")
        check(compare.id == compareID && compare.audioFileName == compareAudio,
              "comparison keeps capture id and audio file")
        check(compare.recordedAt == Date(timeIntervalSince1970: 1_800_002_000), "comparison keeps recording time")
        let archivedText = firstArchived?.text ?? ""
        check(archivedText.contains("ريفيو") && !archivedText.contains("review"),
              "archived text stored verbatim (no substitution)")
        check(compare.transcriptSegments?.first?.hasPrefix(" ") == true, "segments stored verbatim (no trimming)")

        let beforeRetry = compare
        compare.queueTranscription(locale: PilotLocale.arabicEgypt.rawValue)
        compare.beginTranscription()
        compare.fail("engine error")
        check(compare.status == .failed && scalars(compare.transcriptSegments) == scalars(whisperSegments),
              "failed retry keeps current text")
        check(compare.transcriptHistory == beforeRetry.transcriptHistory, "failed retry keeps history")
        check(compare.engine == whisperEngine && compare.resolvedLocale == "ar",
              "failed retry keeps current engine and locale")
        check(compare.processingSeconds == 6.5 && compare.assessment == beforeRetry.assessment,
              "failed retry keeps processing time and rating")
        compare.queueTranscription(locale: PilotLocale.arabicEgypt.rawValue)
        compare.beginTranscription()
        compare.deferTranscription()
        check(compare.status == .pendingTranscription && scalars(compare.transcriptSegments) == scalars(whisperSegments),
              "cancelled retry keeps current text")
        check(compare.transcriptHistory == beforeRetry.transcriptHistory, "cancelled retry keeps history")

        compare.beginTranscription()
        compare.finishTranscription(segments: ["مش Friday، خليها Thursday"], resolvedLocale: "ar-SA",
                                    engine: appleEngine, processingSeconds: 0.9)
        let history = compare.transcriptHistory ?? []
        check(history.count == 2, "each replaced success archived once")
        check(scalars(history.first?.segments) == scalars(appleSegments)
              && scalars(history.last?.segments) == scalars(whisperSegments),
              "history is oldest first, scalar-for-scalar")
        check(history.last?.engine == whisperEngine && history.last?.resolvedLocale == "ar",
              "archived Whisper result keeps engine and detected language")
        check(history.last?.processingSeconds == 6.5 && history.last?.manualAssessment == .unassessed,
              "archived Whisper result keeps processing time and rating")

        // Persistence roundtrip.
        let historyStore = try CaptureStore(directory: dir.appendingPathComponent("history", isDirectory: true))
        try historyStore.save(compare)
        try historyStore.save(legacy)
        let loaded = historyStore.loadAll()
        let reloaded = loaded.records.first { $0.id == compareID }
        let reloadedLegacy = loaded.records.first { $0.id == legacy.id }
        check(loaded.records.count == 2 && loaded.unreadableFiles.isEmpty && reloaded == compare,
              "history survives save/load roundtrip")
        check(scalars(reloaded?.transcriptHistory?.first?.segments) == scalars(appleSegments)
              && scalars(reloaded?.transcriptHistory?.last?.segments) == scalars(whisperSegments),
              "reloaded history text scalar-for-scalar")
        check(reloadedLegacy == legacy, "legacy record roundtrip unchanged")

        // Manual export.
        let exportData = try ResultsExport(records: [compare, legacy]).jsonData()
        let exported = try JSONSerialization.jsonObject(with: exportData) as? [String: Any]
        let appVersion = exported?["app"] as? String
        check(appVersion == "MixCapture Pilot 1.0 (3)", "export version is build 3")
        let exportRows = exported?["results"] as? [[String: Any]] ?? []
        let compareRow = exportRows.first { $0["captureID"] as? String == compareID.uuidString }
        let previous = compareRow?["previousResults"] as? [[String: Any]] ?? []
        let oldest = previous.first ?? [:]
        let newest = previous.last ?? [:]
        check(previous.count == 2, "export includes both previous results")
        check(scalars(oldest["segments"] as? [String]) == scalars(appleSegments)
              && scalars(newest["segments"] as? [String]) == scalars(whisperSegments),
              "exported previous results verbatim")
        let oldestEngine = oldest["engine"] as? String
        let oldestLocale = oldest["resolvedLocale"] as? String
        let oldestRating = oldest["manualAssessment"] as? String
        check(oldestEngine == appleEngine && oldestLocale == "ar-SA" && oldestRating == "needsWork",
              "exported Apple result keeps engine, locale and rating")
        let newestEngine = newest["engine"] as? String
        let newestLocale = newest["resolvedLocale"] as? String
        check(newestEngine == whisperEngine && newestLocale == "ar", "exported Whisper result keeps engine and locale")
        let legacyRow = exportRows.first { $0["captureID"] as? String == legacy.id.uuidString }
        let legacyPrevious = legacyRow?["previousResults"] as? [Any]
        let legacyExportText = legacyRow?["text"] as? String
        check(legacyPrevious?.isEmpty == true && legacyExportText == legacyText,
              "legacy capture exports with empty history and its text")
        let keys = (exportRows.flatMap { $0.keys } + previous.flatMap { $0.keys }).map { $0.lowercased() }
        check(!keys.contains { $0.contains("accuracy") || $0.contains("score") || $0 == "wer" || $0 == "cer" },
              "no automatic accuracy/score fields in export or history")
        check(!String(decoding: exportData, as: UTF8.self).lowercased().contains("accuracy"),
              "history export has no generated accuracy field")
    }
}
