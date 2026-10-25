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

    @ObservationIgnored private let store: LocalItemsStore
    @ObservationIgnored private let delegate = LocalNotificationDelegate()

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
    }

    // MARK: Expenses

    /// `amountText` is what the user typed and reviewed; it is validated here.
    func addExpense(date: Date, title: String, amountText: String, currency: Currency,
                    category: ExpenseCategory, sourceCaptureID: UUID?, sourceTranscript: String?) throws {
        let cleanTitle = try validatedTitle(title)
        guard let minor = parseAmount(amountText) else { throw LocalItemsError.invalidAmount }
        var candidate = snapshot
        candidate.expenses.append(ExpenseItem(date: date, title: cleanTitle, amountMinorUnits: minor,
                                              currency: currency, category: category,
                                              sourceCaptureID: sourceCaptureID,
                                              sourceTranscript: sourceTranscript))
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
        guard let item = reminder(id), item.status != .completed else { throw LocalItemsError.notFound }
        if item.scheduledDate <= Date() { return try update(id, .failed, "الموعد مرّ") }

        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { return try update(id, .failed, error.localizedDescription) }
            settings = await center.notificationSettings()
        }
        // State and time may have changed while the permission prompt was showing.
        guard let current = reminder(id), current.status != .completed else { throw LocalItemsError.notFound }
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
            if let latest = reminder(id), latest.status == .completed { return latest }
            return try update(id, .failed, error.localizedDescription)
        }
        // Completion can occur while add() is suspended. Do not revive a completed reminder.
        if let latest = reminder(id), latest.status == .completed {
            center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
            return latest
        }
        do { return try update(id, .scheduled, nil) } catch {
            // The native request exists but local state is not saved; keep the ID (still saved
            // as pending/failed) so reconcile or retry replaces it without duplicating.
            throw LocalItemsError.uncertain(error.localizedDescription)
        }
    }

    /// Marks completed (also cancels). Pending notification is removed after local state is saved.
    func complete(id: UUID) async throws {
        try update(id, .completed, nil)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    /// Call at startup: removes requests of completed reminders and marks reminders whose
    /// request already exists natively as scheduled.
    func reconcile() async {
        guard storageError == nil else { return }
        let center = UNUserNotificationCenter.current()
        let pending = Set(await center.pendingNotificationRequests().map(\.identifier))
        let completed = snapshot.reminders.filter { $0.status == .completed }.map { $0.id.uuidString }
        center.removePendingNotificationRequests(withIdentifiers: completed)

        var candidate = snapshot
        var changed = false
        for i in candidate.reminders.indices {
            let r = candidate.reminders[i]
            if r.status != .completed, r.status != .scheduled, pending.contains(r.id.uuidString) {
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
        guard changed else { return }
        do { try commit(candidate); saveError = nil } catch { saveError = error.localizedDescription }
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
