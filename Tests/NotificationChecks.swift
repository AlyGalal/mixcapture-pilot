import Foundation
import UserNotifications

/// Pure native trigger calculation: no notification permission, posting, app data or mocks.
@main
struct NotificationChecks {
    static func main() throws {
        let zone = TimeZone(identifier: "Africa/Cairo")!
        var cursor = Date()
        var fall: Date?
        for _ in 0..<4 {
            guard let transition = zone.nextDaylightSavingTimeTransition(after: cursor) else { break }
            if zone.secondsFromGMT(for: transition.addingTimeInterval(-1)) > zone.secondsFromGMT(for: transition) {
                fall = transition; break
            }
            cursor = transition.addingTimeInterval(1)
        }
        guard let fall else { fatalError("Expected a future Cairo fall-back transition in system tzdata") }
        let first = fall.addingTimeInterval(-1800)
        let second = fall.addingTimeInterval(1800)
        var cairo = Calendar(identifier: .gregorian)
        cairo.timeZone = zone
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        guard cairo.dateComponents(fields, from: first) == cairo.dateComponents(fields, from: second) else {
            fatalError("Fixture must represent the same wall-clock time in both repeated hours")
        }
        for instant in [first, second, Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 120)] {
            let trigger = UNCalendarNotificationTrigger(dateMatching: notificationDateComponents(for: instant), repeats: false)
            guard let next = trigger.nextTriggerDate(), abs(next.timeIntervalSince(instant)) < 1 else {
                fatalError("Native trigger changed the intended instant: \(instant) -> \(String(describing: trigger.nextTriggerDate()))")
            }
        }
        print("NotificationChecks OK: ordinary deadline and both repeated Cairo hours keep their exact instants")
    }
}
