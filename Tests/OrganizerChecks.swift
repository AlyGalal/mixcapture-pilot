import Foundation

/// Production snapshot transitions only; no notifications, UI, mocks, or network.
@main
struct OrganizerChecks {
    static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL") \(message)")
        if !condition { failures += 1 }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); check(false, message) }
        catch { check(true, message) }
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let source = UUID(), otherSource = UUID()
        let raw = "ضيف review لمشروع Home؛ دفعت 120.50 EGP في Uber؛ فكرني بعد 10 دقايق"
        let note = OrganizationDraft(kind: .note, title: "review", body: raw, collection: "Home", createdAt: now)
        let expense = OrganizationDraft(kind: .expense, title: "Uber", body: raw, amountText: "120.50",
                                        currency: .EGP, category: .transport, createdAt: now)
        let reminder = OrganizationDraft(kind: .reminder, title: "راجع Home", body: raw,
                                         dueDate: now.addingTimeInterval(600), createdAt: now)
        let unrelated = ExpenseItem(date: now, title: "Keep me", amountMinorUnits: 950,
                                    currency: .USD, category: .other, sourceCaptureID: otherSource,
                                    sourceTranscript: "unrelated original")
        var original = LocalItemsSnapshot()
        original.expenses = [unrelated]
        guard let applied = original.applyingOrganization([note, expense, reminder], sourceID: source, now: now) else {
            check(false, "new source returns a candidate"); exit(1)
        }
        let saved = applied.snapshot
        check(original.library == nil && original.reminders.isEmpty && original.expenses == [unrelated],
              "building a candidate never mutates the input snapshot")
        check(saved.library?.count == 1 && saved.expenses.count == 2 && saved.reminders.count == 1,
              "one candidate contains every clear action")
        check(applied.reminderIDs == [reminder.id] && saved.reminders.first?.status == .pending,
              "reminders are durable pending before native scheduling")
        check(saved.expenses.last?.amountMinorUnits == 12050 && saved.expenses.last?.currency == .EGP,
              "expense transition keeps exact minor units and currency")
        check(saved.library?.first?.body == raw && saved.expenses.last?.sourceTranscript == raw &&
              saved.reminders.first?.sourceTranscript == raw, "every action retains the original text")
        check(applied.receipt.status == .applied && applied.receipt.originalText == raw,
              "receipt retains source text independently of created actions")
        check(saved.applyingOrganization([note, expense, reminder], sourceID: source, now: now) == nil,
              "a committed source cannot duplicate any action")

        let reviewSource = UUID()
        let invalidExpense = OrganizationDraft(kind: .expense, title: "Coffee", body: "paid too much?",
                                               amountText: "12.345", createdAt: now)
        let invalidReminder = OrganizationDraft(kind: .reminder, title: "Past", body: "past reminder",
                                                dueDate: now.addingTimeInterval(-60), createdAt: now)
        guard let queued = saved.applyingOrganization([invalidExpense, invalidReminder], sourceID: reviewSource, now: now) else {
            check(false, "invalid drafts produce a review candidate"); exit(1)
        }
        check(queued.snapshot.expenses == saved.expenses && queued.snapshot.reminders == saved.reminders,
              "invalid amounts and dates never become saved actions")
        check(queued.receipt.status == .review && queued.snapshot.reviewQueue?.count == 2 && queued.reminderIDs.isEmpty,
              "invalid actions become review drafts with no native scheduling IDs")
        guard let storedDraft = queued.snapshot.reviewQueue?.first else { exit(1) }
        var edited = storedDraft
        edited.amountText = "-1"
        rejects("review rejects invalid edited money without consuming the draft") {
            _ = try queued.snapshot.applyingReview(edited, now: now)
        }
        check(queued.snapshot.reviewQueue?.first == storedDraft, "failed review leaves the queued draft intact")
        rejects("review rejects a still-past reminder date") {
            _ = try queued.snapshot.applyingReview(queued.snapshot.reviewQueue!.last!, now: now)
        }
        edited.amountText = "42.25"
        edited.title = "Reviewed coffee"
        edited.body = "forged replacement"
        edited.sourceCaptureID = UUID()
        edited.createdAt = now.addingTimeInterval(999)
        edited.requiresReview = false
        let reviewed = try queued.snapshot.applyingReview(edited, now: now)
        guard case .expense(let reviewedExpense) = reviewed.record else { check(false, "reviewed kind"); exit(1) }
        check(reviewedExpense.amountMinorUnits == 4225 && reviewedExpense.title == "Reviewed coffee",
              "review applies corrected metadata")
        check(reviewedExpense.sourceTranscript == storedDraft.body && reviewedExpense.sourceCaptureID == reviewSource &&
              reviewedExpense.date == storedDraft.createdAt, "review cannot forge original text, source, or creation time")
        check(reviewed.snapshot.reviewQueue?.count == 1, "review consumes only the applied draft")
        rejects("the same review cannot be applied twice") { _ = try reviewed.snapshot.applyingReview(edited, now: now) }

        let undone = try reviewed.snapshot.undoingOrganization(sourceID: source)
        check(undone.removedReminderIDs == [reminder.id], "undo returns only this source's notification IDs")
        check(undone.snapshot.library?.isEmpty == true && undone.snapshot.reminders.isEmpty &&
              undone.snapshot.expenses.contains(unrelated) && undone.snapshot.expenses.contains(reviewedExpense),
              "undo removes only the chosen source's actions")
        check(undone.snapshot.receipt(for: source)?.status == .undone &&
              undone.snapshot.receipt(for: source)?.originalText == raw, "undo keeps the source receipt and original text")
        check(undone.snapshot.applyingOrganization([note], sourceID: source, now: now) == nil,
              "an undone source is never replayed automatically")
        let restoredOldBackup = try undone.snapshot.merging(saved)
        check(restoredOldBackup.expenses.filter { $0.sourceCaptureID == source }.isEmpty &&
              restoredOldBackup.reminders.filter { $0.sourceCaptureID == source }.isEmpty &&
              restoredOldBackup.library?.filter { $0.sourceCaptureID == source }.isEmpty == true,
              "an old backup cannot resurrect a source already undone on this device")
        let undoReview = try undone.snapshot.undoingOrganization(sourceID: reviewSource)
        check(undoReview.snapshot.reviewQueue?.isEmpty == true && undoReview.snapshot.expenses == [unrelated],
              "undo clears remaining review drafts and their applied siblings")

        let legacy = try JSONDecoder().decode(LocalItemsSnapshot.self, from: Data(#"{"expenses":[],"reminders":[]}"#.utf8))
        check(legacy.library == nil && legacy.reviewQueue == nil && legacy.organizationReceipts == nil,
              "legacy JSON decodes without inventing organizer arrays")
        let oldReminderJSON = #"{"expenses":[],"reminders":[{"id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","title":"Legacy reminder","scheduledDate":0,"status":"pending"}]}"#
        let oldReminder = try JSONDecoder().decode(LocalItemsSnapshot.self, from: Data(oldReminderJSON.utf8))
        check(oldReminder.reminders.first?.automaticSchedulingEligible == nil,
              "legacy reminders do not acquire automatic scheduling eligibility")
        let encoded = try JSONEncoder().encode(reviewed.snapshot)
        check(try JSONDecoder().decode(LocalItemsSnapshot.self, from: encoded) == reviewed.snapshot,
              "new organizer metadata roundtrips losslessly")

        var incoming = LocalItemsSnapshot()
        var collision = unrelated
        collision.title = "Must not replace existing"
        collision.amountMinorUnits = 1
        let newExpense = ExpenseItem(date: now, title: "Imported", amountMinorUnits: 2500,
                                    currency: .EUR, category: .bills, sourceCaptureID: nil, sourceTranscript: nil)
        incoming.expenses = [collision, newExpense]
        var importedReminder = ReminderItem(title: "Imported alert", scheduledDate: now.addingTimeInterval(3600),
                                            sourceCaptureID: nil, sourceTranscript: nil)
        importedReminder.status = .scheduled
        incoming.reminders = [importedReminder]
        incoming.library = [OrganizerItem(kind: .calendar, title: "Imported meeting", body: "original event",
                                          dueDate: now.addingTimeInterval(3600), endDate: now.addingTimeInterval(5400),
                                          externalCalendarID: "foreign-device-id")]
        let merged = try original.merging(incoming)
        check(merged.expenses == [unrelated, newExpense], "additive import keeps existing UUID values and adds new records")
        check(merged.reminders.first?.status == .pending && merged.reminders.first?.automaticSchedulingEligible == false,
              "import never preserves a false native scheduling claim or auto-schedules later")
        check(merged.library?.first?.externalCalendarID == nil && merged.library?.first?.calendarSyncEligible == false,
              "import clears foreign native identifiers and disables later automatic event publication")
        var outbox = OrganizerItem(kind: .calendar, title: "Meeting", body: "raw",
                                  dueDate: now.addingTimeInterval(600), endDate: now.addingTimeInterval(1200))
        check(outbox.needsCalendarPublication(at: now), "new explicit calendar event enters native outbox")
        outbox.externalCalendarID = "pending:source"
        check(outbox.needsCalendarPublication(at: now), "unacknowledged native save remains retryable")
        outbox.externalCalendarID = "undo:pending:source"
        check(!outbox.needsCalendarPublication(at: now), "durable undo intent prevents event recreation")
        outbox.externalCalendarID = "native-event-id"
        check(!outbox.needsCalendarPublication(at: now), "acknowledged event is not posted again")
        outbox.externalCalendarID = nil; outbox.calendarSyncEligible = false
        check(!outbox.needsCalendarPublication(at: now), "imported event never enters a later sync")
        outbox.calendarSyncEligible = true
        check(!outbox.needsCalendarPublication(at: now.addingTimeInterval(1800)), "past local event is not published later")
        check(try merged.merging(incoming) == merged, "reimporting the same backup is idempotent")
        incoming.expenses.append(ExpenseItem(date: now, title: "Invalid", amountMinorUnits: 0,
                                             currency: .EGP, category: .other, sourceCaptureID: nil, sourceTranscript: nil))
        rejects("one invalid imported record rejects the whole merge") { _ = try original.merging(incoming) }
        check(original.expenses == [unrelated], "rejected import cannot partially alter the receiver")
        var duplicate = LocalItemsSnapshot()
        duplicate.expenses = [newExpense, newExpense]
        rejects("backup rejects duplicate UUIDs rather than silently dropping conflicting rows") {
            _ = try original.merging(duplicate)
        }
        var invalidCalendar = LocalItemsSnapshot()
        invalidCalendar.library = [OrganizerItem(kind: .calendar, title: "No end", body: "raw", dueDate: now)]
        rejects("backup rejects a calendar item with missing end time") { _ = try original.merging(invalidCalendar) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("organizer-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalItemsStore(directory: directory)
        try store.save(saved)
        check(try store.load() == saved, "atomic store saves the complete action/receipt candidate")
        try store.save(undone.snapshot)
        check(try store.load() == undone.snapshot, "atomic replacement persists a complete undo candidate")
        let corrupt = Data("{broken-json".utf8)
        try corrupt.write(to: store.fileURL, options: .atomic)
        rejects("corrupt storage read throws") { _ = try store.load() }
        check(try Data(contentsOf: store.fileURL) == corrupt, "failed load leaves corrupt source bytes untouched")
        if failures > 0 { print("OrganizerChecks: \(failures) failures"); exit(1) }
        print("OrganizerChecks OK")
    }
}
