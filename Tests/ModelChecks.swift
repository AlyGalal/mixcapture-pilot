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

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("All model checks passed")
    }
}
