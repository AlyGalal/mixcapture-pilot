import EventKit
import Foundation
import Observation

/// One-way creation of explicitly timed local events. Full access is needed to find our
/// ownership URL again after a crash between EventKit save and local acknowledgement.
@MainActor @Observable
final class CalendarBridge {
    private struct BridgeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let shared = CalendarBridge()
    private(set) var enabled = UserDefaults.standard.bool(forKey: "calendarSyncEnabled")
    private(set) var statusMessage: String?
    private(set) var isBusy = false
    @ObservationIgnored private let events = EKEventStore()

    func connectAndSync() async throws {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard try await events.requestFullAccessToEvents() else {
            throw BridgeError(message: "Calendar access was not granted. Events are saved in MixCapture.")
        }
        enabled = true
        UserDefaults.standard.set(true, forKey: "calendarSyncEnabled")
        events.reset()
        try synchronize()
    }

    func disconnect() {
        enabled = false
        UserDefaults.standard.set(false, forKey: "calendarSyncEnabled")
        statusMessage = "Automatic calendar additions are off. Existing calendar events are kept."
    }

    func syncPending() async {
        guard enabled, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { try synchronize() }
        catch { statusMessage = error.localizedDescription }
    }

    private func synchronize() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw BridgeError(message: "Calendar access is not allowed. Enable it in iPhone Settings.")
        }
        let model = LocalItemsModel.shared
        var count = 0
        // No suspension between native save and local acknowledgement; another sync cannot race.
        for item in model.libraryItems where item.needsCalendarPublication(at: Date()) {
            guard let start = item.dueDate, let end = item.endDate, end > start else { continue }
            // Past imported/old events are kept local, never posted to the user's calendar later.
            guard start > Date() else { continue }
            let event: EKEvent
            if let existing = matchingEvent(item) {
                event = existing
            } else {
                guard let calendar = events.defaultCalendarForNewEvents, calendar.allowsContentModifications else {
                    throw BridgeError(message: "No writable calendar is available on this device.")
                }
                event = EKEvent(eventStore: events)
                event.calendar = calendar
                event.title = item.title
                event.startDate = start
                event.endDate = end
                event.url = Self.marker(item.id)
                // Durable outbox marker precedes the external write. Undo can now distinguish
                // an unacknowledged write from an event that was never sent to EventKit.
                try model.updateExternalCalendarID(id: item.id, value: "pending:\(item.id.uuidString)")
                try events.save(event, span: .thisEvent, commit: true)
            }
            guard let identifier = event.eventIdentifier else {
                throw BridgeError(message: "The event was added, but its identifier was unavailable. You can safely retry syncing.")
            }
            try model.updateExternalCalendarID(id: item.id, value: identifier)
            count += 1
        }
        statusMessage = count > 0 ? "Added \(count) events to your calendar." : "Calendar connected. New events with clear dates and times are added automatically."
    }

    /// Removes only events whose URL proves that this app created them, then undoes local data.
    /// Retrying after an interrupted undo is safe: missing native events are already removed.
    func undoSource(_ sourceID: UUID) throws {
        guard !isBusy else { throw BridgeError(message: "Wait for calendar syncing to finish, then try again.") }
        let model = LocalItemsModel.shared
        let owned = model.libraryItems.filter { $0.kind == .calendar && $0.sourceCaptureID == sourceID }
        if owned.contains(where: { $0.externalCalendarID != nil }) {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
                throw BridgeError(message: "Grant calendar access again before undoing its events.")
            }
            // Mark every event in one local commit before removing any external event.
            try model.prepareCalendarUndo(sourceID: sourceID)
        }
        for item in owned where item.externalCalendarID != nil {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { continue }
            if let event = matchingEvent(item) {
                try events.remove(event, span: .thisEvent, commit: true)
            }
        }
        try model.undoOrganization(sourceID: sourceID)
    }

    private func matchingEvent(_ item: OrganizerItem) -> EKEvent? {
        let marker = Self.marker(item.id)
        let id = item.externalCalendarID.map { $0.hasPrefix("undo:") ? String($0.dropFirst(5)) : $0 }
        if let id, let event = events.event(withIdentifier: id), event.url == marker {
            return event
        }
        guard let start = item.dueDate, let end = item.endDate else { return nil }
        let predicate = events.predicateForEvents(withStart: start.addingTimeInterval(-86400),
                                                  end: end.addingTimeInterval(86400), calendars: nil)
        return events.events(matching: predicate).first { $0.url == marker }
    }

    private static func marker(_ id: UUID) -> URL {
        URL(string: "mixcapture://event/\(id.uuidString)")!
    }
}
