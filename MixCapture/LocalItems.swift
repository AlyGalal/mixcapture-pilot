import Foundation

// Foundation-only models, validation and persistence for local expenses and reminders.

enum Currency: String, Codable, CaseIterable, Identifiable {
    case EGP, USD, EUR
    var id: String { rawValue }
}

enum ExpenseCategory: String, Codable, CaseIterable, Identifiable {
    case food, groceries, transport, bills, shopping, health, other
    var id: String { rawValue }
}

struct ExpenseItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var title: String
    /// Positive integer minor units; never a floating-point money value.
    var amountMinorUnits: Int64
    var currency: Currency
    var category: ExpenseCategory
    var sourceCaptureID: UUID?
    var sourceTranscript: String?
}

enum ReminderStatus: String, Codable {
    case pending, scheduled, needsPermission, failed, completed
}

struct ReminderItem: Codable, Identifiable, Equatable {
    /// Also the UNNotificationRequest identifier.
    var id = UUID()
    var title: String
    var scheduledDate: Date
    var sourceCaptureID: UUID?
    var sourceTranscript: String?
    var status: ReminderStatus = .pending
    var scheduleError: String?
    /// Only new or explicitly scheduled reminders recover automatically; imports never activate.
    var automaticSchedulingEligible: Bool? = true
}

struct LocalItemsSnapshot: Codable, Equatable {
    var expenses: [ExpenseItem] = []
    var reminders: [ReminderItem] = []
    var library: [OrganizerItem]? = nil
    var reviewQueue: [OrganizationDraft]? = nil
    var organizationReceipts: [OrganizationReceipt]? = nil
}

enum LocalItemsError: LocalizedError {
    case invalidAmount, emptyTitle, pastDate, notFound
    case storageUnavailable(String)
    case uncertain(String)
    case missingDate, invalidDateRange, notSupported, invalidText, invalidCalendar
    case invalidBackup(String)

    var errorDescription: String? {
        switch self {
        case .invalidAmount: return "المبلغ غير صالح. استخدم أرقاماً مع كسر عشري حتى خانتين."
        case .emptyTitle: return "العنوان مطلوب."
        case .pastDate: return "الموعد مرّ. اختر وقتاً في المستقبل."
        case .notFound: return "العنصر غير موجود."
        case .missingDate: return "اختر تاريخًا ووقتًا واضحين."
        case .invalidDateRange: return "نهاية الموعد يجب أن تكون بعد بدايته."
        case .notSupported: return "هذا النوع غير مدعوم."
        case .invalidText: return "البيانات غير صالحة أو النص طويل جدًا."
        case .invalidCalendar: return "أكمل مزامنة الموعد أو تراجع عنه قبل تعديل توقيته."
        case .invalidBackup(let detail): return "النسخة الاحتياطية غير صالحة: \(detail)"
        case .storageUnavailable(let detail): return "التخزين المحلي غير متاح، لم يتم الحفظ. \(detail)"
        case .uncertain(let detail): return "جُدول الإشعار على الجهاز لكن تعذّر حفظ الحالة محلياً؛ ستؤكده المحاولة التالية دون تكرار. \(detail)"
        }
    }
}

// MARK: - Validation

/// Parses a whole string such as "12.30" or "٣٥٠٫٥٠" into minor units (2 decimals).
/// Accepts Western/Arabic-Indic/Extended digits and "." or "٫". Rejects anything else
/// (signs, grouping, spaces inside, >2 fraction digits, zero, overflow).
func parseAmount(_ text: String) -> Int64? {
    var ascii = String.UnicodeScalarView()
    for s in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
        switch s.value {
        case 0x30...0x39: ascii.append(s)
        case 0x660...0x669: ascii.append(Unicode.Scalar(s.value - 0x660 + 0x30)!)
        case 0x6F0...0x6F9: ascii.append(Unicode.Scalar(s.value - 0x6F0 + 0x30)!)
        case 0x2E, 0x66B: ascii.append(".")
        default: return nil
        }
    }
    let parts = String(ascii).split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2, let whole = parts.first, !whole.isEmpty, whole.count <= 19,
          let major = Int64(whole) else { return nil }
    var minor: Int64 = 0
    if parts.count == 2 {
        let frac = parts[1]
        guard (1...2).contains(frac.count), let f = Int64(frac) else { return nil }
        minor = frac.count == 1 ? f * 10 : f
    }
    let (scaled, overflow) = major.multipliedReportingOverflow(by: 100)
    guard !overflow, scaled <= Int64.max - minor else { return nil }
    let total = scaled + minor
    return total > 0 ? total : nil
}

/// Western-digit display, e.g. 35050 -> "350.50".
func formatAmount(_ minorUnits: Int64, _ currency: Currency) -> String {
    formatAmount(Decimal(minorUnits), currency)
}

func formatAmount(_ minorUnits: Decimal, _ currency: Currency) -> String {
    let parts = NSDecimalNumber(decimal: minorUnits / 100).stringValue.split(separator: ".", omittingEmptySubsequences: false)
    let fraction = parts.count > 1 ? String(parts[1]) : ""
    return "\(parts[0]).\(fraction)\(String(repeating: "0", count: max(0, 2 - fraction.count))) \(currency.rawValue)"
}

func validatedTitle(_ title: String) throws -> String {
    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { throw LocalItemsError.emptyTitle }
    return t
}

func validateFutureDate(_ date: Date, now: Date = Date()) throws {
    guard date.timeIntervalSince1970.isFinite else { throw LocalItemsError.invalidText }
    guard date > now else { throw LocalItemsError.pastDate }
}

/// A one-off reminder denotes an instant. UTC components keep repeated DST hours distinct.
func notificationDateComponents(for date: Date) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    parts.calendar = calendar
    parts.timeZone = calendar.timeZone
    return parts
}

// MARK: - Monthly summary

struct CurrencyTotal: Equatable {
    let currency: Currency
    let totalMinorUnits: Decimal
    let byCategory: [ExpenseCategory: Decimal]
}

/// Totals for the month, one entry per currency present. Currencies are never combined.
func monthlySummary(_ items: [ExpenseItem], month: Date, calendar: Calendar = .current) -> [CurrencyTotal] {
    var grouped: [Currency: [ExpenseCategory: Decimal]] = [:]
    for item in items where calendar.isDate(item.date, equalTo: month, toGranularity: .month) {
        grouped[item.currency, default: [:]][item.category, default: 0] += Decimal(item.amountMinorUnits)
    }
    return Currency.allCases.compactMap { c in
        guard let cats = grouped[c] else { return nil }
        return CurrencyTotal(currency: c, totalMinorUnits: cats.values.reduce(0, +), byCategory: cats)
    }
}

// MARK: - Persistence

struct LocalItemsStore {
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("items.json") }

    static var standard: LocalItemsStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return LocalItemsStore(directory: docs.appendingPathComponent("LocalItems", isDirectory: true))
    }

    /// Missing file -> empty snapshot. Unreadable or corrupt file -> throws (caller must not write).
    func load() throws -> LocalItemsSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LocalItemsSnapshot() }
        return try JSONDecoder().decode(LocalItemsSnapshot.self, from: Data(contentsOf: fileURL))
    }

    /// Atomic replace inside a directory excluded from backup.
    func save(_ snapshot: LocalItemsSnapshot) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try dir.setResourceValues(values)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Human-readable JSON for optional manual sharing.
func exportJSON(_ snapshot: LocalItemsSnapshot) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(snapshot) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
