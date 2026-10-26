import Foundation
import Observation
import UserNotifications

/// Shows local notifications as banner + sound while the app is in the foreground.
final class LocalNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor @Observable
final class LocalItemsModel {
    static let shared = LocalItemsModel()

    private(set) var snapshot = LocalItemsSnapshot()
    /// Set when existing data could not be read; all writes are then refused.
    private(set) var storageError: String?
    /// Last background (non-editor) save problem, e.g. during reconcile.
    private(set) var saveError: String?

    var automaticOrganizationEnabled = UserDefaults.standard.object(forKey: "automaticOrganizationEnabled") == nil
        || UserDefaults.standard.bool(forKey: "automaticOrganizationEnabled") {
        didSet { UserDefaults.standard.set(automaticOrganizationEnabled, forKey: "automaticOrganizationEnabled") }
    }
    var libraryItems: [OrganizerItem] { snapshot.library ?? [] }
    var reviewItems: [OrganizationDraft] { snapshot.reviewQueue ?? [] }
    var organizationReceipts: [OrganizationReceipt] { snapshot.organizationReceipts ?? [] }

    @ObservationIgnored private let store: LocalItemsStore
    @ObservationIgnored private let delegate = LocalNotificationDelegate()
    @ObservationIgnored private var isReconciling = false

    init(store: LocalItemsStore = .standard) {
        self.store = store
        do {
            snapshot = try store.load()
        } catch {
            storageError = "تعذّرت قراءة البيانات المحلية الحالية، وتم إيقاف الحفظ حتى لا تُستبدل. \(error.localizedDescription)"
        }
        UNUserNotificationCenter.current().delegate = delegate
    }

    func exportJSON() -> String { LocalItemsMessages.export(snapshot) }

    // MARK: Persistence

    /// Persists the candidate first; the visible snapshot changes only on success.
    private func commit(_ candidate: LocalItemsSnapshot) throws {
        if let storageError { throw LocalItemsError.storageUnavailable(storageError) }
        do { try store.save(candidate) } catch {
            throw LocalItemsError.storageUnavailable(error.localizedDescription)
        }
        snapshot = candidate
        saveError = nil
    }

    // MARK: Organization

    func receipt(for sourceID: UUID) -> OrganizationReceipt? { snapshot.receipt(for: sourceID) }

    @discardableResult
    func organize(text: String, sourceID: UUID, recordedAt: Date = Date()) async throws -> OrganizationReceipt {
        if let receipt = receipt(for: sourceID) { return receipt }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100_000,
              recordedAt.timeIntervalSinceReferenceDate.isFinite else { throw LocalItemsError.invalidText }
        let drafts = OrganizerParser.parse(text, now: recordedAt)
        guard !drafts.isEmpty,
              let result = snapshot.applyingOrganization(drafts, sourceID: sourceID, now: Date()) else {
            throw LocalItemsError.invalidText
        }
        try commit(result.snapshot) // all actions and their receipt are durable before any permission prompt
        for id in result.reminderIDs {
            do { _ = try await schedule(id: id) }
            catch {
                if let current = reminder(id), current.status != .completed { saveError = error.localizedDescription }
            }
        }
        return receipt(for: sourceID) ?? result.receipt
    }

    func applyReview(_ draft: OrganizationDraft) async throws {
        let result = try snapshot.applyingReview(draft, now: Date())
        try commit(result.snapshot)
        if case .reminder(let item) = result.record {
            do { _ = try await schedule(id: item.id) }
            catch {
                if let current = reminder(item.id), current.status != .completed { saveError = error.localizedDescription }
            }
        }
    }

    func undoOrganization(sourceID: UUID) throws {
        let result = try snapshot.undoingOrganization(sourceID: sourceID)
        try commit(result.snapshot)
        removeNotifications(result.removedReminderIDs)
    }

    func upsertLibrary(_ proposed: OrganizerItem) throws {
        var item = proposed
        var candidate = snapshot
        if let index = candidate.library?.firstIndex(where: { $0.id == item.id }), let existing = candidate.library?[index] {
            if existing.sourceCaptureID != nil {
                item.body = existing.body
                item.sourceCaptureID = existing.sourceCaptureID
                item.createdAt = existing.createdAt
            }
            item.externalCalendarID = existing.externalCalendarID
            item.calendarSyncEligible = existing.calendarSyncEligible
            if let external = existing.externalCalendarID,
               external.hasPrefix("pending:") || external.hasPrefix("undo:"),
               item.dueDate != existing.dueDate || item.endDate != existing.endDate {
                throw LocalItemsError.invalidCalendar
            }
            candidate.library?[index] = try validatedLibraryItem(item)
        } else {
            item.externalCalendarID = nil // a manually-created row cannot claim an external event
            candidate.library = (candidate.library ?? []) + [try validatedLibraryItem(item)]
        }
        try commit(candidate)
    }

    func deleteLibrary(id: UUID) throws {
        guard libraryItems.contains(where: { $0.id == id }) else { throw LocalItemsError.notFound }
        var candidate = snapshot
        candidate.library?.removeAll { $0.id == id }
        try commit(candidate)
    }

    func toggleLibrary(id: UUID) throws {
        var candidate = snapshot
        guard let index = candidate.library?.firstIndex(where: { $0.id == id }),
              let item = candidate.library?[index] else { throw LocalItemsError.notFound }
        guard item.kind == .task || item.kind == .shopping else { throw LocalItemsError.notSupported }
        candidate.library?[index].isCompleted.toggle()
        try commit(candidate)
    }

    func updateExternalCalendarID(id: UUID, value: String) throws {
        var candidate = snapshot
        guard let index = candidate.library?.firstIndex(where: { $0.id == id }),
              candidate.library?[index].kind == .calendar else { throw LocalItemsError.notFound }
        guard !value.isEmpty else { throw LocalItemsError.invalidText }
        candidate.library?[index].externalCalendarID = value
        try commit(candidate)
    }

    func mergeBackup(data: Data) throws {
        guard !data.isEmpty, data.count <= 10 * 1_024 * 1_024 else {
            throw LocalItemsError.invalidBackup("حجم الملف غير صالح؛ الحد الأقصى 10 MB.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming: LocalItemsSnapshot
        do { incoming = try decoder.decode(LocalItemsSnapshot.self, from: data) }
        catch {
            do { incoming = try JSONDecoder().decode(LocalItemsSnapshot.self, from: data) }
            catch { throw LocalItemsError.invalidBackup(error.localizedDescription) }
        }
        try commit(snapshot.merging(incoming)) // import never schedules notifications or calls EventKit
    }

    // MARK: Expenses

    /// `amountText` is what the user typed and reviewed; it is validated here.
    func addExpense(date: Date, title: String, amountText: String, currency: Currency,
                    category: ExpenseCategory, sourceCaptureID: UUID?, sourceTranscript: String?) throws {
        let cleanTitle = try validatedTitle(title)
        guard let minor = parseAmount(amountText) else { throw LocalItemsError.invalidAmount }
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw LocalItemsError.invalidText }
        var candidate = snapshot
        candidate.expenses.append(ExpenseItem(date: date, title: cleanTitle, amountMinorUnits: minor,
                                              currency: currency, category: category,
                                              sourceCaptureID: sourceCaptureID,
                                              sourceTranscript: sourceTranscript))
        try commit(candidate)
    }

    func upsertExpense(_ proposed: ExpenseItem) throws {
        var item = proposed
        item.title = try validatedTitle(item.title)
        guard item.amountMinorUnits > 0 else { throw LocalItemsError.invalidAmount }
        guard item.date.timeIntervalSinceReferenceDate.isFinite else { throw LocalItemsError.invalidText }
        var candidate = snapshot
        if let index = candidate.expenses.firstIndex(where: { $0.id == item.id }) {
            let existing = candidate.expenses[index]
            item.sourceCaptureID = existing.sourceCaptureID
            item.sourceTranscript = existing.sourceTranscript
            candidate.expenses[index] = item
        } else { candidate.expenses.append(item) }
        try commit(candidate)
    }

    func deleteExpense(id: UUID) throws {
        guard snapshot.expenses.contains(where: { $0.id == id }) else { throw LocalItemsError.notFound }
        var candidate = snapshot
        candidate.expenses.removeAll { $0.id == id }
        try commit(candidate)
    }

    // MARK: Reminders

    func reminder(_ id: UUID) -> ReminderItem? { snapshot.reminders.first { $0.id == id } }

    /// Saves as pending before any permission prompt; the editor retains this ID for retries.
    func createReminder(title: String, date: Date, sourceCaptureID: UUID?, sourceTranscript: String?) throws -> ReminderItem {
        let cleanTitle = try validatedTitle(title)
        try validateFutureDate(date)
        let item = ReminderItem(title: cleanTitle, scheduledDate: date,
                                sourceCaptureID: sourceCaptureID, sourceTranscript: sourceTranscript)
        var candidate = snapshot
        candidate.reminders.append(item)
        try commit(candidate)
        return item
    }

    /// (Re)schedules a saved reminder using its stable UUID as request identifier,
    /// so a retry replaces the existing request instead of duplicating it.
    @discardableResult
    func schedule(id: UUID) async throws -> ReminderItem {
        try await schedule(id: id, requestPermission: true)
    }

    @discardableResult
    private func schedule(id: UUID, requestPermission: Bool) async throws -> ReminderItem {
        guard let item = reminder(id), item.status != .completed else { throw LocalItemsError.notFound }
        if item.scheduledDate <= Date() { return try update(id, .failed, "الموعد مرّ") }
        if item.automaticSchedulingEligible != true {
            var candidate = snapshot
            if let index = candidate.reminders.firstIndex(where: { $0.id == id }) {
                candidate.reminders[index].automaticSchedulingEligible = true
            }
            try commit(candidate)
        }

        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        var current = try currentReminderOrCancel(id)
        if current.status == .completed { return current }
        if settings.authorizationStatus == .notDetermined && requestPermission {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch {
                current = try currentReminderOrCancel(id)
                if current.status == .completed { return current }
                return try update(id, .failed, error.localizedDescription)
            }
            current = try currentReminderOrCancel(id)
            if current.status == .completed { return current }
            settings = await center.notificationSettings()
        }
        // State and time may have changed while the permission prompt was showing.
        current = try currentReminderOrCancel(id)
        if current.status == .completed { return current }
        if current.scheduledDate <= Date() { return try update(id, .failed, "الموعد مرّ") }

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default:
            return try update(id, .needsPermission, "الإشعارات غير مسموحة. فعّلها من الإعدادات ثم أعد المحاولة.")
        }

        let content = UNMutableNotificationContent()
        content.title = current.title
        content.sound = .default
        var parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                     from: current.scheduledDate)
        parts.calendar = Calendar.current
        parts.timeZone = Calendar.current.timeZone
        let request = UNNotificationRequest(identifier: id.uuidString, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        do { try await center.add(request) } catch {
            let latest = try currentReminderOrCancel(id)
            if latest.status == .completed { return latest }
            return try update(id, .failed, error.localizedDescription)
        }
        // Completion or undo can happen while add() is suspended; remove the late native request.
        let latest = try currentReminderOrCancel(id)
        if latest.status == .completed { return latest }
        do { return try update(id, .scheduled, nil) } catch {
            // The native request exists but local state is not saved; keep the ID (still saved
            // as pending/failed) so reconcile or retry replaces it without duplicating.
            throw LocalItemsError.uncertain(error.localizedDescription)
        }
    }

    /// Marks completed (also cancels). Pending notification is removed after local state is saved.
    func complete(id: UUID) async throws {
        try update(id, .completed, nil)
        removeNotifications([id])
    }

    /// Call at startup: removes requests of completed reminders and marks reminders whose
    /// request already exists natively as scheduled.
    func reconcile() async {
        guard storageError == nil, !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        let center = UNUserNotificationCenter.current()
        let queriedSnapshot = snapshot
        let pending = Set(await center.pendingNotificationRequests().map(\.identifier))
        let delivered = Set(await center.deliveredNotifications().map { $0.request.identifier })
        // A save/schedule can finish during the native query; leave newer state for the next refresh.
        guard snapshot == queriedSnapshot else { return }
        let liveIDs = Set(snapshot.reminders.filter {
            $0.status != .completed && $0.automaticSchedulingEligible != false
        }.map { $0.id.uuidString })
        // All app notification requests currently use reminder UUIDs. This also recovers a crash
        // after local undo committed but before native cancellation ran.
        let stale = pending.union(delivered).filter { UUID(uuidString: $0) != nil && !liveIDs.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        center.removeDeliveredNotifications(withIdentifiers: Array(stale))

        var candidate = snapshot
        var changed = false
        for i in candidate.reminders.indices {
            let r = candidate.reminders[i]
            if r.status != .completed, r.status != .scheduled, r.automaticSchedulingEligible != false,
               pending.contains(r.id.uuidString) {
                candidate.reminders[i].status = .scheduled
                candidate.reminders[i].scheduleError = nil
                changed = true
            }
            if r.status == .scheduled, r.scheduledDate > Date(), !pending.contains(r.id.uuidString) {
                candidate.reminders[i].status = .failed
                candidate.reminders[i].scheduleError = "لا يوجد إشعار معلّق على الجهاز؛ أعد الجدولة."
                changed = true
            }
        }
        if changed {
            do { try commit(candidate) } catch { saveError = error.localizedDescription; return }
        }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return
        }
        let recover = snapshot.reminders.filter {
            $0.status == .pending && $0.automaticSchedulingEligible == true && $0.scheduledDate > Date()
        }.map(\.id)
        for id in recover {
            guard let current = reminder(id), current.status == .pending,
                  current.automaticSchedulingEligible == true else { continue }
            do { _ = try await schedule(id: id, requestPermission: false) }
            catch {
                if let latest = reminder(id), latest.status != .completed { saveError = error.localizedDescription }
            }
        }
    }

    private func removeNotifications(_ ids: [UUID]) {
        let identifiers = ids.map(\.uuidString)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Checks after every native suspension. Removed rows (undo) and completed rows cannot revive.
    private func currentReminderOrCancel(_ id: UUID) throws -> ReminderItem {
        guard let item = reminder(id) else {
            removeNotifications([id])
            throw LocalItemsError.notFound
        }
        guard item.automaticSchedulingEligible == true else {
            removeNotifications([id])
            throw LocalItemsError.notFound
        }
        if item.status == .completed { removeNotifications([id]) }
        return item
    }

    @discardableResult
    private func update(_ id: UUID, _ status: ReminderStatus, _ error: String?) throws -> ReminderItem {
        var candidate = snapshot
        guard let i = candidate.reminders.firstIndex(where: { $0.id == id }) else { throw LocalItemsError.notFound }
        candidate.reminders[i].status = status
        candidate.reminders[i].scheduleError = error
        try commit(candidate)
        return candidate.reminders[i]
    }
}

private enum LocalItemsMessages {
    static func export(_ s: LocalItemsSnapshot) -> String { exportJSON(s) }
}
