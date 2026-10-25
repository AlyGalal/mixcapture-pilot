import Foundation

@main
struct LocalItemsChecks {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        if !condition() {
            print("FAIL (line \(line)): \(message)")
            exit(1)
        }
    }

    static func main() throws {
        // Amounts
        check(parseAmount("٣٥٠٫٥٠") == 35050, "arabic 350.50")
        check(parseAmount("12.30") == 1230, "12.30")
        check(parseAmount("12") == 1200, "whole")
        check(parseAmount("0.5") == 50, "one fraction digit")
        check(parseAmount(" 7 ") == 700, "trim")
        check(parseAmount("۱۲٫۳۰") == 1230, "extended Arabic digits")
        for bad in ["", "abc", "12abc", "1.234", "0", "0.00", "-5", "1,000", "1.000,50", "1.2.3", ".5", "5.", "1 2", "99999999999999999999", "92233720368547758.08"] {
            check(parseAmount(bad) == nil, "rejects \(bad)")
        }

        // Persistence
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("items-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = LocalItemsStore(directory: tmp.appendingPathComponent("LocalItems"))
        let source = UUID()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try validateFutureDate(when.addingTimeInterval(1), now: when)
        for past in [when, when.addingTimeInterval(-1)] {
            var rejected = false
            do { try validateFutureDate(past, now: when) } catch { rejected = true }
            check(rejected, "reminder requires a future date")
        }
        let snapshot = LocalItemsSnapshot(
            expenses: [ExpenseItem(date: when, title: "قهوة coffee", amountMinorUnits: 35050, currency: .EGP,
                                   category: .food, sourceCaptureID: source, sourceTranscript: "نص تجريبي")],
            reminders: [ReminderItem(title: "اتصال call", scheduledDate: when, sourceCaptureID: source)])
        let empty = try store.load()
        check(empty == LocalItemsSnapshot(), "missing file loads empty")
        try store.save(snapshot)
        let loaded = try store.load()
        check(loaded == snapshot, "roundtrip")
        check(loaded.expenses[0].sourceCaptureID == source && loaded.expenses[0].sourceTranscript == "نص تجريبي"
              && loaded.expenses[0].title == "قهوة coffee", "roundtrip text and source id")

        // Corrupt file: load throws and the bytes are untouched.
        try Data("not json".utf8).write(to: store.fileURL)
        var threw = false
        do { _ = try store.load() } catch { threw = true }
        check(threw, "corrupt file throws")
        let corruptBytes = try Data(contentsOf: store.fileURL)
        check(corruptBytes == Data("not json".utf8), "corrupt file untouched")

        // Failed save (directory path occupied by a regular file) leaves that file untouched.
        let blocker = tmp.appendingPathComponent("blocker")
        try Data("keep".utf8).write(to: blocker)
        threw = false
        do { try LocalItemsStore(directory: blocker).save(snapshot) } catch { threw = true }
        check(threw, "save failure throws")
        let blockerBytes = try Data(contentsOf: blocker)
        check(blockerBytes == Data("keep".utf8), "failed save leaves data")

        // Monthly totals never combine currencies.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func day(_ m: Int) -> Date { cal.date(from: DateComponents(year: 2025, month: m, day: 10))! }
        func item(_ m: Int, _ amount: Int64, _ c: Currency, _ cat: ExpenseCategory) -> ExpenseItem {
            ExpenseItem(date: day(m), title: "x", amountMinorUnits: amount, currency: c, category: cat)
        }
        let totals = monthlySummary([item(3, 1230, .EGP, .food), item(3, 35050, .EGP, .bills),
                                     item(3, 500, .USD, .food), item(4, 999, .EGP, .food)],
                                    month: day(3), calendar: cal)
        check(totals.count == 2, "one entry per currency")
        check(totals[0].currency == .EGP && totals[0].totalMinorUnits == 36280, "EGP total")
        check(totals[0].byCategory[.food] == 1230 && totals[0].byCategory[.bills] == 35050, "EGP categories")
        check(totals[1].currency == .USD && totals[1].totalMinorUnits == 500, "USD separate")
        check(formatAmount(Int64(35050), .EGP) == "350.50 EGP" && formatAmount(Int64(5), .USD) == "0.05 USD", "format")
        check(parseAmount("92233720368547758.07") == Int64.max, "largest integer minor-unit amount")
        let large = monthlySummary([item(3, Int64.max, .EGP, .food), item(3, Int64.max, .EGP, .food)],
                                   month: day(3), calendar: cal)
        check(large[0].totalMinorUnits == Decimal(Int64.max) * 2, "monthly aggregation does not overflow Int64")

        print("LocalItemsChecks OK")
    }
}
