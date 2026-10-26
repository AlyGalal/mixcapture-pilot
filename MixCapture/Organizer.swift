import Foundation

// Foundation-only organizer models, a deterministic phrase parser for a fixed set of explicit
// Arabic/Egyptian/English commands, and pure snapshot transitions used by LocalItemsModel.
// Anything the parser is not sure about becomes a review draft. This is not general language
// understanding: no network, no model, no invented dates, amounts, names or recurrence.

// MARK: - Models

enum OrganizerKind: String, Codable, CaseIterable, Identifiable {
    case note, task, shopping, recipe, calendar
    var id: String { rawValue }
    var label: String {
        switch self {
        case .note: return "Note"
        case .task: return "Task"
        case .shopping: return "Shopping item"
        case .recipe: return "Recipe"
        case .calendar: return "Event"
        }
    }
}

struct OrganizerItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: OrganizerKind
    var title: String
    /// Full original text, kept even when metadata was extracted.
    var body: String
    var collection: String = ""
    var createdAt: Date = Date()
    var dueDate: Date? = nil
    var endDate: Date? = nil
    var ingredients: [String] = []
    var steps: [String] = []
    var isCompleted: Bool = false
    var sourceCaptureID: UUID? = nil
    var externalCalendarID: String? = nil
    var calendarSyncEligible: Bool? = true

    func needsCalendarPublication(at now: Date) -> Bool {
        kind == .calendar && calendarSyncEligible == true &&
        (externalCalendarID == nil || externalCalendarID?.hasPrefix("pending:") == true) &&
        dueDate.map { $0 > now } == true && endDate.map { $0 > (dueDate ?? $0) } == true
    }

    init(id: UUID = UUID(), kind: OrganizerKind, title: String, body: String, collection: String = "",
         createdAt: Date = Date(), dueDate: Date? = nil, endDate: Date? = nil, ingredients: [String] = [],
         steps: [String] = [], isCompleted: Bool = false, sourceCaptureID: UUID? = nil,
         externalCalendarID: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.collection = collection
        self.createdAt = createdAt
        self.dueDate = dueDate
        self.endDate = endDate
        self.ingredients = ingredients
        self.steps = steps
        self.isCompleted = isCompleted
        self.sourceCaptureID = sourceCaptureID
        self.externalCalendarID = externalCalendarID
    }
}

enum OrganizationKind: String, Codable, CaseIterable, Identifiable {
    case note, task, shopping, recipe, calendar, reminder, expense
    var id: String { rawValue }
    var label: String {
        switch self {
        case .note: return "Note"
        case .task: return "Task"
        case .shopping: return "Shopping item"
        case .recipe: return "Recipe"
        case .calendar: return "Event"
        case .reminder: return "Reminder"
        case .expense: return "Expense"
        }
    }
}

struct OrganizationDraft: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: OrganizationKind
    var title: String
    /// Full original text, kept even when metadata was extracted.
    var body: String
    var collection: String = ""
    /// Nil for legacy drafts. A newly requested list cannot silently merge into an old one.
    var newShoppingListRequested: Bool? = nil
    var amountText: String = ""
    var currency: Currency = .EGP
    var category: ExpenseCategory = .other
    var dueDate: Date? = nil
    var endDate: Date? = nil
    var ingredients: [String] = []
    var steps: [String] = []
    var requiresReview: Bool = false
    var reason: String? = nil
    var sourceCaptureID: UUID? = nil
    var createdAt: Date = Date()

    init(id: UUID = UUID(), kind: OrganizationKind, title: String, body: String, collection: String = "",
         amountText: String = "", currency: Currency = .EGP, category: ExpenseCategory = .other,
         dueDate: Date? = nil, endDate: Date? = nil, ingredients: [String] = [], steps: [String] = [],
         requiresReview: Bool = false, reason: String? = nil, sourceCaptureID: UUID? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.collection = collection
        self.amountText = amountText
        self.currency = currency
        self.category = category
        self.dueDate = dueDate
        self.endDate = endDate
        self.ingredients = ingredients
        self.steps = steps
        self.requiresReview = requiresReview
        self.reason = reason
        self.sourceCaptureID = sourceCaptureID
        self.createdAt = createdAt
    }
}

struct OrganizationReceipt: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case applied, review, undone }
    /// The source capture / typed command UUID. One receipt per source.
    var id: UUID
    var createdAt: Date
    var summary: String
    var status: Status
    var originalText: String? = nil
}

// MARK: - Parser

enum OrganizerParser {
    /// Every draft's `body` is the untouched input. Clear commands come back ready to apply;
    /// uncertain ones come back with `requiresReview` and a reason.
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> [OrganizationDraft] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let parser = PhraseParser(now: now, calendar: calendar)
        let doc = Doc(text)
        if text.utf16.count > 100_000 {
            return [parser.review(.note, doc, text, "This text is too long to organize automatically. Review it manually.")]
        }
        if doc.has(#"^\s*(?:هل|لو|اذا|if|did|was|were|have|has|what|why|when|how|is|are|do|does|should)(?![\p{L}])"#) {
            return [parser.review(.note, doc, text, "This may be a question or possibility. It was not executed as a command.")]
        }
        if let recipe = parser.recipe(doc, text) { return [recipe] }
        if doc.has(Rx.negation) || doc.has(#"\?\s*$"#) {
            return [parser.review(parser.classify(doc)?.kind ?? .note, doc, text,
                                  "This contains a negation or correction. Review the full source.")]
        }
        if doc.has(Rx.modificationRequest) || doc.has(Rx.developmentRequest) {
            return [parser.review(parser.classify(doc)?.kind ?? .note, doc, text,
                                  "This requests an update or idea development. Review the intended action before saving.")]
        }
        let segments = parser.segments(doc)
        guard segments.count > 1 else { return parser.parseSegment(doc, text, previous: nil) }
        var drafts: [OrganizationDraft] = []
        for segment in segments { drafts += parser.parseSegment(segment, text, previous: drafts.last) }
        return drafts
    }
}

private func regex(_ pattern: String) -> NSRegularExpression {
    // Patterns are constants exercised by Tests/OrganizerChecks.swift.
    try! NSRegularExpression(pattern: pattern)
}

private func collapse(_ s: String) -> String {
    s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func shortTitle(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return line.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        .trimmingCharacters(in: Doc.edges)
}

/// Original text plus a normalized copy of identical UTF-16 length used only for matching,
/// so ranges found in `norm` always slice the untouched `orig`.
private struct Doc {
    let orig: NSString
    let norm: NSString
    static let edges = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",،:;؛-–—.!?؟\"'()"))
        .union(.nonBaseCharacters)

    init(_ text: String) {
        orig = text as NSString
        var scalars = String.UnicodeScalarView()
        for u in text.unicodeScalars { scalars.append(Doc.fold(u)) }
        norm = String(scalars) as NSString
    }

    private init(orig: NSString, norm: NSString) {
        self.orig = orig
        self.norm = norm
    }

    /// One BMP scalar to one BMP scalar: digits to ASCII, ASCII lowercase, common Arabic letter variants.
    static func fold(_ u: Unicode.Scalar) -> Unicode.Scalar {
        let v = u.value
        let mapped: UInt32
        switch v {
        case 0x41...0x5A: mapped = v + 0x20
        case 0x660...0x669: mapped = v - 0x660 + 0x30
        case 0x6F0...0x6F9: mapped = v - 0x6F0 + 0x30
        case 0x66B: mapped = 0x2E
        case 0x66C, 0x60C: mapped = 0x2C
        case 0x61B: mapped = 0x3B
        case 0x61F: mapped = 0x3F
        case 0x2018, 0x2019: mapped = 0x27
        case 0x2010...0x2015, 0x2212: mapped = 0x2D
        case 0x622, 0x623, 0x625, 0x671: mapped = 0x627
        case 0x649, 0x6CC: mapped = 0x64A
        case 0x629: mapped = 0x647
        case 0x6A9: mapped = 0x643
        default: mapped = v
        }
        return Unicode.Scalar(mapped) ?? u
    }

    var length: Int { norm.length }
    /// Original text, trimmed of edge whitespace/punctuation, inner whitespace collapsed.
    var text: String { collapse((orig as String).trimmingCharacters(in: Doc.edges)) }
    var key: String { collapse((norm as String).trimmingCharacters(in: Doc.edges)) }

    func sub(from start: Int, to end: Int) -> Doc {
        let r = NSRange(location: start, length: max(0, end - start))
        return Doc(orig: orig.substring(with: r) as NSString, norm: norm.substring(with: r) as NSString)
    }
    func o(_ r: NSRange) -> String { orig.substring(with: r) }
    func n(_ r: NSRange) -> String { norm.substring(with: r) }
    func group(_ m: NSTextCheckingResult, _ i: Int) -> NSRange? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : r
    }
    func gn(_ m: NSTextCheckingResult, _ i: Int) -> String? { group(m, i).map(n) }

    func all(_ pattern: String) -> [NSTextCheckingResult] {
        regex(pattern).matches(in: norm as String, range: NSRange(location: 0, length: length))
    }
    func first(_ pattern: String, from start: Int = 0) -> NSTextCheckingResult? {
        guard start <= length else { return nil }
        return regex(pattern).firstMatch(in: norm as String, range: NSRange(location: start, length: length - start))
    }
    func has(_ pattern: String) -> Bool { first(pattern) != nil }

    /// Replaces ranges (plus trailing Arabic diacritics) by one space in both copies.
    func removing(_ ranges: [NSRange]) -> Doc {
        var extended: [NSRange] = []
        for r in ranges where r.location != NSNotFound && r.length > 0 {
            var end = NSMaxRange(r)
            while end < length {
                let c = norm.character(at: end)
                guard (0x064B...0x065F).contains(c) || c == 0x0670 else { break }
                end += 1
            }
            extended.append(NSRange(location: r.location, length: end - r.location))
        }
        var merged: [NSRange] = []
        for r in extended.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, r.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, r)
            } else {
                merged.append(r)
            }
        }
        let o = NSMutableString(string: orig as String), n = NSMutableString(string: norm as String)
        for r in merged.reversed() {
            o.replaceCharacters(in: r, with: " ")
            n.replaceCharacters(in: r, with: " ")
        }
        return Doc(orig: o, norm: n)
    }

    /// Drops connector words (matched on the normalized copy) at the start, and optionally the end.
    func stripped(_ leading: String, trailing: String? = nil) -> Doc {
        var d = self
        for _ in 0..<4 {
            var cut: [NSRange] = []
            if let m = d.first(#"^[\s\p{P}]*(?:"# + leading + #")(?![\p{L}\p{N}])"#) { cut.append(m.range) }
            if let trailing, let m = d.first(#"(?<![\p{L}\p{N}])(?:"# + trailing + #")[\s\p{P}]*$"#) { cut.append(m.range) }
            if cut.isEmpty { break }
            d = d.removing(cut)
        }
        return d
    }
}

/// Phrase tables. All literals are in normalized form (ه not ة, ي not ى, ا not أ/إ/آ, lowercase).
private enum Rx {
    static let b = #"(?<![\p{L}\p{N}])"#
    static let e = #"(?![\p{L}\p{N}])"#
    static func word(_ alternatives: String) -> String { b + "(?:" + alternatives + ")" + e }
    /// Whole word that may carry the Arabic conjunction prefix و/ف.
    static func w(_ alternatives: String) -> String { b + "(?:و|ف)?(?:" + alternatives + ")" + e }
    /// Keyword that may carry attached Arabic prepositions/article.
    static func stem(_ alternatives: String) -> String { b + "(?:و|ف)?(?:ب|لل|ل)?(?:ال)?(?:" + alternatives + ")" + e }
    static func alternation(_ words: [String]) -> String {
        words.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }.joined(separator: "|")
    }

    static let numbers: [String: Int] = [
        "واحد": 1, "واحده": 1, "اتنين": 2, "اثنين": 2, "تلاته": 3, "ثلاثه": 3, "تلات": 3, "ثلاث": 3,
        "اربعه": 4, "اربع": 4, "خمسه": 5, "خمس": 5, "سته": 6, "ست": 6, "سبعه": 7, "سبع": 7,
        "تمانيه": 8, "ثمانيه": 8, "تسعه": 9, "تسع": 9, "عشره": 10, "عشر": 10, "حداشر": 11, "احداشر": 11,
        "اتناشر": 12, "اطناشر": 12, "تلتاشر": 13, "اربعتاشر": 14, "خمستاشر": 15, "ستاشر": 16,
        "سبعتاشر": 17, "تمنتاشر": 18, "تسعتاشر": 19, "عشرين": 20, "تلاتين": 30, "ثلاثين": 30,
        "اربعين": 40, "خمسين": 50, "ستين": 60, "سبعين": 70, "تمانين": 80, "ثمانين": 80, "تسعين": 90,
        "ميتين": 200, "تلتميه": 300, "ربعميه": 400, "خمسميه": 500, "ستميه": 600, "سبعميه": 700,
        "تمنميه": 800, "تسعميه": 900, "الفين": 2000,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let hundreds: Set<String> = ["ميه", "مائه", "مئه", "مايه", "hundred"]
    static let thousands: Set<String> = ["الف", "الاف", "تلاف", "thousand"]
    static let numberAlt = alternation(Array(numbers.keys) + Array(hundreds) + Array(thousands))
    static let hourAlt = alternation(numbers.filter { (1...12).contains($0.value) }.map { $0.key })
    static let numberWord = #"(?<![^\s\-و])(?:"# + numberAlt + #")(?![\p{L}])"#

    static let negation = w(#"متسجلش|متسجليش|ماتسجلش|متفكرنيش|ماتفكرنيش|متضيفش|ماتضيفش|متحطش|ماتحطش|متعملش|ماتعملش|متشتريش|ماتشتريش|مش|مو|لا|بلاش|الغي|الغيه|الغيها|الغاء|كنسل|امسح|امسحه|امسحها|احذف|شيل|don't|dont|do\s+not|not|never|cancel|delete|remove|no"#)
    static let reminderHead = w(#"فكرني|ذكرني|فكريني|ذكريني|نبهني|نبهيني|remind\s+me|reminder|remind"#)
    static let modificationRequest = #"^\s*(?:(?:غير|غيّر|عدل|عدّل)\p{L}{0,2}|change|update|move)(?![\p{L}\p{N}])"#
    static let developmentRequest = #"^\s*(?:ساعدني\s+(?:اطور|develop)|help\s+me\s+develop)(?![\p{L}\p{N}])"#
    static let expenseHead = w(#"سجل\s+مصروف|سجلي\s+مصروف|سجل\s+مصاريف|ضيف\s+مصروف|مصروف|مصاريف|دفعت|صرفت|اشتريت|log\s+(?:an\s+)?expense|add\s+(?:an\s+)?expense|expense|i\s+paid|i\s+spent|i\s+bought|paid|spent|bought"#)
    static let calendarHead = w(#"اجتماع|ميتينج|ميتنج|ميعاد|معاد|موعد|مقابله|meeting|appointment|event"#)
    static let taskHead = w(#"مهمه|تاسك|task|todo|to-do"#)
    static let noteHead = w(#"ملاحظه|ملحوظه|نوت|note"#)
    static let buyVerb = w(#"عايز\s+اشتري|عاوز\s+اشتري|عايزه\s+اشتري|عاوزه\s+اشتري|محتاج\s+اشتري|محتاجه\s+اشتري|لازم\s+اشتري|لازم\s+نشتري|هشتري|هنشتري|نشتري|اشتري|اشتريلي|i\s+need\s+to\s+buy|need\s+to\s+buy|want\s+to\s+buy|buy"#)
    static let addVerbStart = #"^\s*(?:ضيف|ضيفي|ضيفلي|اضيف|حط|حطي|حطلي|زود|سجل|سجلي|add|put)(?![\p{L}\p{N}])"#
    static let shoppingAddStart = #"^\s*(?:(?:لل[\sـ]*[^,،:;؛.!?؟\n\"“”]+?[,،:]?\s+|for\s+[^,،:;؛.!?؟\n\"“”]+?,\s+))?(?:(?:انا\s+)?(?:عايز|عاوزه|عاوز|عايزه|محتاج|محتاجه)\s+|(?:i\s+)?(?:want|need|would\s+like)\s+to\s+)?(?:احط|اضيف|ضيف|ضيفي|ضيفلي|حط|حطي|حطلي|زود|سجل|سجلي|add|put)(?![\p{L}\p{N}])"#
    static let calendarVerbStart = #"^\s*(?:حط|حطي|حطلي|ضيف|ضيفي|ضيفلي|اضيف|اعمل|اعملي|سجل|سجلي|احجز|احجزلي|احجزي|schedule|add|create|put|book|set\s+up|new)(?![\p{L}\p{N}])"#
    static let calendarTarget = word(#"(?:(?:في|علي|لل|ل|to|on|in)\s*)?(?:the\s+|my\s+)?(?:ال)?(?:كالندر|كاليندر|تقويم|calendar)"#)
    static let imperativeStart = #"^\s*(?:و|ف)?(?:(?:ضيف|حط|سجل|اعمل|ابعت|كلم|اتصل|روح|افتح|شغل|احجز|ادفع|هات|خلي|غير|عدل|اكتب|احفظ|شيل|امسح|نظم|رتب|جيب|دور|شوف|اطلب|حول|فكر|ذكر)\p{L}{0,3}|add|put|log|save|call|send|email|text|book|schedule|create|make|set|open|go|pay|tell|ask|check|get|order|delete|remove|cancel|move|change|update|transfer|remember|buy)(?![\p{L}\p{N}])"#

    static let project = b + #"(?:(?:لل|ل|في|علي|الي|تبع|to|for|in|under|on)\s*)?(?:the\s+)?(?:ال)?(?:مشروع|بروجكت|بروجيكت|project)\s+([^:\n]+?)\s*(?=:|\n|$)"#
    static let arabicList = b + #"(?:(?:لل|ل|في|علي|الي)\s*)?(?:ال)?(?:قائمه|قايمه|ليسته|لسته)(?![\p{L}\p{N}])(?:\s+(?:ال)?(?:مشتريات|شراء|شرا|تسوق|حاجات|طلبات)(?![\p{L}\p{N}]))?(?:\s+([^\n]+?))?\s*$"#
    static let englishList = b + #"(?:(?:to|on|in|into|في|علي|الي|لل|ل)[\sـ]*)?(?:the\s+|my\s+|ال[\sـ]*)?(?:shopping\s*|grocery\s*)?list(?:ه)?(?![\p{L}\p{N}])(?:\s+([^\n]+?))?\s*$"#
    static let newShoppingList = #"^\s*(?:(?:انا\s+)?(?:عايز|عاوزه|عاوز|عايزه|محتاج|محتاجه)\s+)?(?:ابتدي\s+)?(?:اعمل|انشئ|create|make)\s+(?:a\s+)?(?:new\s+)?(?:ال[\sـ]*)?(?:(?:shopping\s*|grocery\s*)?list(?:ه)?|قائمه|قايمه|ليسته|لسته)(?:\s+(?:جديده|جديد|new))?(?:\s+(?:اسمها|اسمه|باسم|named|called)\s+(.+?))?\s+(?:احط|اضيف|حط|ضيف|add|put)\s+(?:فيها|فيه|in\s+it|into\s+it)\s+"#
    static let purchaseTail = #"(?:\s*[,،.!؛;]\s*|\s+)(?:كل(?:ه)?\s+(?:ده|دا|دول)|(?:كل\s+)?الحاجات\s+دي)\s+(?:انا\s+)?(?:(?:عايز|عاوزه|عاوز|عايزه|ناوي)\s+)?(?:انزل\s+)?(?:(?:اشتري|هشتري)(?:ه|ها|هم)?|اجيب(?:ه|ها|هم)?)(?![\p{L}\p{N}])[\s\S]*$"#
    static let genericLists: Set<String> = ["المشتريات", "مشتريات", "الشراء", "التسوق", "الحاجات", "الطلبات", "shopping", "grocery"]
    static let taskLists: Set<String> = ["المهام", "مهام", "tasks", "todo", "to-do", "to do"]
    static let quantity = #"علبه|علبتين|علب|كيلو|كيلوين|جرام|نص|ربع|ازازه|ازازتين|ازايز|كيس|كيسين|اكياس|باكو|باكوين|باكيت|باكيتين|كرتونه|كرتونتين|رغيف|حبه|حبتين|دسته|طبق|لتر|لترين|واحد|واحده|اتنين|تلاته|اربعه|خمسه|سته|سبعه|تمانيه|تسعه|عشره"#
    /// Only clear delimiters; a word-initial و splits only before Latin/digits, ال or a quantity word.
    static let arabicItemSeparator = #"\s*[,،+&;\n]\s*|\s+و\s+|\s+و(?=(?:[a-z0-9]|ال\p{L}|(?:"# + quantity + #")(?![\p{L}])))"#
    static let itemSeparator = arabicItemSeparator + #"|\s+and\s+"#
    static let repeatedItem = #"\s+(?:و\s*)?(?:احط|اضيف|حط|ضيف)\s+فيها\s+"#
    static let stepSeparator = #"\s*\n+\s*|[.!?;](?=\s|$)\s*|\s+(?:ثم|then|وبعدين|بعدين|وبعد\s+كده|بعد\s+كده|بعد\s+كدا)\s+"#
    static let segmentSeparator = #"\s*[\n;]+\s*|\s+(?=و(?:فكرني|ذكرني|فكريني|ذكريني|سجل\s+مصروف|سجلي\s+مصروف)(?![\p{L}\p{N}]))|\s+and\s+(?=(?:remind\s+me|log\s+(?:an\s+)?expense|add\s+(?:an\s+)?expense)(?![\p{L}\p{N}]))"#

    static let recipeHead = #"^\s*(?:(?:سجل|سجلي|احفظ|ضيف|اكتب|save|add|new)\s+)?(?:(?:a|the)\s+)?(?:وصفه|recipe)(?![\p{L}\p{N}])(?:\s+for(?![\p{L}\p{N}]))?"#
    static let ingredientsMarker = word(#"المكونات|مكونات|ingredients"#) + #"\s*:?"#
    static let stepsMarker = word(#"طريقه\s+التحضير|الطريقه|طريقه|الخطوات|خطوات|steps|method|directions|instructions"#) + #"\s*:?"#

    static let recurrence = w(#"كل\s+(?:يوم|اسبوع|شهر|سنه|ساعه|ساعتين|صبح|صباح|ليله|يومين|\p{L}*(?:سبت|حد|اتنين|اثنين|تلات|ثلاثاء|اربع|خميس|جمعه))|يوميا|اسبوعيا|شهريا|every|daily|weekly|monthly|each\s+(?:day|week|month|morning|night)"#)
    static let slashDate = #"(?<![\p{N}])\d{1,4}\s*[/\-]\s*\d{1,2}(?:\s*[/\-]\s*\d{1,4})?(?![\p{N}])"#
    static let unsupportedDate = slashDate + "|" + word(#"يناير|فبراير|مارس|ابريل|مايو|يونيو|يوليو|اغسطس|سبتمبر|اكتوبر|نوفمبر|ديسمبر|january|february|march|april|june|july|august|september|october|november|december|الاسبوع\s+الجاي|الاسبوع\s+اللي\s+جاي|الشهر\s+الجاي|next\s+week|next\s+month|weekend|الويك\s+اند|الويكند"#)
    static let pastDay = w(#"امبارح|امس|اول\s+امبارح|yesterday|last\s+night"#)
    static let day = b + #"و?(بعد\s+بكره|بعد\s+بكرا|(?:the\s+)?day\s+after\s+tomorrow|بكره|بكرا|tomorrow|النهارده|النهارد|انهارده|اليوم|today|tonight)"# + e
    static let weekdayNames: [String: Int] = [
        "الحد": 1, "الاحد": 1, "الاتنين": 2, "الاثنين": 2, "التلات": 3, "التلاتا": 3, "التلاتاء": 3,
        "الثلاثا": 3, "الثلاثاء": 3, "الاربع": 4, "الاربعا": 4, "الاربعاء": 4, "الخميس": 5, "الجمعه": 6,
        "السبت": 7, "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6,
        "saturday": 7,
    ]
    static let weekday = b + #"و?(?:يوم\s+|on\s+)?(?:(next|this|coming)\s+)?("# + alternation(Array(weekdayNames.keys)) + #")(?:\s+(?:الجاي|اللي\s+جاي|الجايه|اللي\s+جايه|القادم|القادمه))?"# + e
    static let noon = b + #"(?:at\s+)?(noon|midday|midnight|نص\s+الليل|منتصف\s+الليل)"# + e
    static let minuteUnit = #"دقايق|دقائق|دقيقه|minutes|minute|mins|min"#
    static let hourUnit = #"ساعات|ساعه|hours|hour|hrs|hr"#
    static let dayUnit = #"ايام|يوم|days|day|اسابيع|اسبوع|weeks|week"#
    static let phraseMinutes: [String: Int] = [
        "ساعه ونص": 90, "ساعه الا ربع": 45, "نص ساعه": 30, "نصف ساعه": 30, "ربع ساعه": 15, "ساعتين": 120,
        "ساعه": 60, "دقيقتين": 2, "دقيقه": 1, "half an hour": 30, "an hour": 60, "one hour": 60,
        "a minute": 1, "a quarter of an hour": 15, "a quarter hour": 15,
    ]
    static let phraseAlt = alternation(phraseMinutes.keys.map { $0.replacingOccurrences(of: " ", with: #"\s+"#) })
    static func span(_ units: String) -> String { #"(\d{1,4}|"# + numberAlt + #")\s*("# + units + ")" }
    static let relative = b + #"(?:بعد|in|within|after)\s+(?:"# + span(minuteUnit + "|" + hourUnit + "|" + dayUnit) + "|(" + phraseAlt + "))" + e
    static let duration = b + #"(?:لمده|مده|مدته|مدتها|for|lasting)\s+(?:"# + span(minuteUnit + "|" + hourUnit) + "|(" + phraseAlt + "))" + e
    static let meridiem = #"a\.m\.|a\.m|am|p\.m\.|p\.m|pm|الصبح|صباحا|الصباح|صباح|الفجر|بالليل|بليل|الليل|مساءا|مساء|المسا|بالمسا|العصر|المغرب|العشا|بعد\s+الضهر|بعد\s+الظهر|الضهر|الظهر|ضهرا|ظهرا|ص|م"#
    static let time = b + #"(?:(الساعه|at|@)\s*)?(\d{1,2}|"# + hourAlt + #")(?::(\d{2}))?(?:\s*(ونص|و\s+نص|وربع|و\s+ربع|وتلت|و\s+تلت|الا\s+ربع|الا\s+تلت|and\s+a\s+half))?(?:\s*("# + meridiem + "))?" + e

    static let egp = #"جنيه\s+مصري|جنيهات|جنيها|جنيه|ج\.م\.?|egp|l\.e\.?|le|egyptian\s+pounds?"#
    static let usd = #"دولارات|دولار|us\s+dollars?|usd|dollars?|\$"#
    static let eur = #"يورو|euros?|eur|€"#
    static let currency = "(" + egp + "|" + usd + "|" + eur + ")"
    static let currencyWord = #"(?<![\p{L}])"# + currency + e
    static let digitAmount = #"(?<![\p{N}.,])(-?)(\d(?:[\d.,]*\d)?)\s*"# + currency + e
    static let prefixAmount = b + #"(\$|€|us\$|usd|egp|eur)\s*(-?)(\d(?:[\d.,]*\d)?)(?![\p{N}.,])"#
    static let wordAmount = b + "((?:" + numberAlt + #")(?![\p{L}])(?:\s*(?:و|and|-)?\s*(?:"# + numberAlt + #")(?![\p{L}]))*)\s*"# + currency + e
    static let categories: [(ExpenseCategory, String)] = [
        (.transport, #"uber|careem|indrive|didi|taxi|cab|تاكسي|اوبر|كريم|اندرايف|مواصلات|بنزين|fuel|metro|مترو|ميكروباص|توكتوك|تكتوك|bus|اتوبيس|قطر|train|parking|جراج"#),
        (.food, #"قهوه|coffee|كافيه|cafe|اكل|غدا|غدي|عشا|فطار|lunch|dinner|breakfast|restaurant|مطعم|food|pizza|بيتزا|كشري|شاي|tea|سندوتش|سندوتشات|sandwich|برجر|burger|talabat|طلبات"#),
        (.groceries, #"سوبرماركت|سوبر\s+ماركت|supermarket|grocery|groceries|بقاله|خضار|فاكهه|عيش|لبن|بيض|جبنه|رز|سكر|زيت|milk|eggs|bread|vegetables|fruit|carrefour|كارفور"#),
        (.bills, #"كهربا|كهرباء|electricity|انترنت|internet|فاتوره|bill|bills|rent|ايجار|مياه|اشتراك|subscription"#),
        (.health, #"دكتور|doctor|صيدليه|pharmacy|دوا|دواء|medicine|hospital|مستشفي|تحاليل|clinic|عياده"#),
        (.shopping, #"هدوم|clothes|لبس|جزمه|shoes|amazon|امازون"#),
    ]

    static let reminderLead = #"ان|اني|انك|to|that|about|عن|of|ب|عشان|علشان"#
    static let expenseLead = #"في|ف|علي|لل|ل|عشان|علشان|حق|تمن|ثمن|بتاع|ب|for|on|at|in|to|of|i"#
    static let expenseTrail = #"ب|في|for|at|of|on|بسعر"#
    static let itemLead = #"to|في|علي|for|on|in|a|an|the|ان"#
    static let noteLead = #"عن|about|that|ان"#
    static let pronouns: Set<String> = ["بيه", "بيها", "به", "بها", "ده", "دي", "عليه", "عليها", "it", "about it", "that", "this"]
}

// ponytail: bounded phrase grammar; add rules from failing examples, keep unknown language in review.
private struct PhraseParser {
    let now: Date
    let calendar: Calendar

    enum Found { case absent, date(Date), unclear(String) }
    struct Moment { var found: Found; var ranges: [NSRange] }
    enum Clock { case ok(hour: Int, minute: Int), unclear(String) }
    struct Amount { var range: NSRange; var text: String?; var currency: Currency }

    func make(_ kind: OrganizationKind, _ title: String, _ body: String) -> OrganizationDraft {
        OrganizationDraft(kind: kind, title: title, body: body, createdAt: now)
    }

    func review(_ kind: OrganizationKind, _ d: Doc, _ body: String, _ reason: String, title: String = "") -> OrganizationDraft {
        var t = title
        if t.isEmpty { t = shortTitle(d.text) }
        if t.isEmpty { t = kind.label }
        var out = make(kind, t, body)
        out.requiresReview = true
        out.reason = reason
        return out
    }

    func segments(_ d: Doc) -> [Doc] {
        var out: [Doc] = []
        var start = 0
        for m in d.all(Rx.segmentSeparator) {
            out.append(d.sub(from: start, to: m.range.location))
            start = NSMaxRange(m.range)
        }
        out.append(d.sub(from: start, to: d.length))
        return out.filter { !$0.text.isEmpty }
    }

    func split(_ d: Doc, _ separator: String) -> [String] {
        var out: [String] = []
        var start = 0
        for m in d.all(separator) {
            out.append(d.sub(from: start, to: m.range.location).text)
            start = NSMaxRange(m.range)
        }
        out.append(d.sub(from: start, to: d.length).text)
        return out.filter { !$0.isEmpty }
    }

    func listMatch(_ d: Doc) -> NSTextCheckingResult? { d.first(Rx.arabicList) ?? d.first(Rx.englishList) }

    func classify(_ d: Doc) -> (kind: OrganizationKind, range: NSRange)? {
        var best: (kind: OrganizationKind, range: NSRange)?
        func consider(_ kind: OrganizationKind, _ range: NSRange?) {
            guard let range else { return }
            if let current = best, current.range.location <= range.location { return }
            best = (kind, range)
        }
        consider(.reminder, d.first(Rx.reminderHead)?.range)
        consider(.expense, d.first(Rx.expenseHead)?.range)
        consider(.calendar, d.first(Rx.calendarHead)?.range)
        if d.has(Rx.calendarVerbStart) { consider(.calendar, d.first(Rx.calendarTarget)?.range) }
        let add = d.first(Rx.shoppingAddStart)
        consider(.shopping, d.first(Rx.newShoppingList)?.range ?? d.first(Rx.buyVerb)?.range ??
                 (add == nil ? nil : listMatch(d)?.range))
        var taskRange = d.first(Rx.taskHead)?.range
        if taskRange == nil, d.has(Rx.project) { taskRange = d.first(Rx.addVerbStart)?.range }
        consider(.task, taskRange)
        consider(.note, d.first(Rx.noteHead)?.range)
        return best
    }

    func parseSegment(_ d: Doc, _ body: String, previous: OrganizationDraft?) -> [OrganizationDraft] {
        let head = classify(d)
        if d.has(Rx.negation) {
            return [review(head?.kind ?? .note, d, body, "This contains a negation or cancellation. Nothing was executed automatically.")]
        }
        guard let head else { return [fallback(d, body)] }
        switch head.kind {
        case .reminder: return [reminder(d, head.range, body, previous)]
        case .expense: return [expense(d, head.range, body)]
        case .calendar: return [calendarEvent(d, body)]
        case .shopping: return shopping(d, body)
        case .task: return [task(d, body)]
        case .note: return [note(d, head.range, body)]
        case .recipe: return [fallback(d, body)]
        }
    }

    // MARK: Kinds

    func reminder(_ d: Doc, _ head: NSRange, _ body: String, _ previous: OrganizationDraft?) -> OrganizationDraft {
        let when = moment(d)
        let rest = d.removing([head] + when.ranges).stripped(Rx.reminderLead)
        var title = rest.text
        if Rx.pronouns.contains(rest.key) {
            guard let previous else { return review(.reminder, d, body, "This reminder refers to something that was not specified.") }
            title = previous.title
        }
        if d.has(Rx.recurrence) { return review(.reminder, d, body, "Recurring reminders require manual review.", title: title) }
        switch when.found {
        case .absent: return review(.reminder, d, body, "No specific date and time were given.", title: title)
        case .unclear(let reason): return review(.reminder, d, body, reason, title: title)
        case .date(let date):
            var out = title.isEmpty ? review(.reminder, d, body, "The reminder text is unclear.") : make(.reminder, title, body)
            out.dueDate = date
            return out
        }
    }

    func expense(_ d: Doc, _ head: NSRange, _ body: String) -> OrganizationDraft {
        let leading = d.sub(from: 0, to: head.location).key
        let found = amounts(d)
        let rest = d.removing([head] + found.map { $0.range }).stripped(Rx.expenseLead, trailing: Rx.expenseTrail)
        var out = make(.expense, rest.text.isEmpty ? OrganizationKind.expense.label : rest.text, body)
        out.category = category(d)
        if found.count == 1 {
            out.amountText = found[0].text ?? ""
            out.currency = found[0].currency
        }
        var reason: String?
        switch moment(d).found {
        case .absent: break
        default: reason = "The expense time is stated separately. Review its date and time."
        }
        if !leading.isEmpty && !["انا", "please"].contains(leading) {
            reason = "This expense is part of another statement. Confirm that it is your expense before saving."
        } else if d.has(Rx.pastDay) || d.has(Rx.weekday) || d.has(Rx.slashDate) || d.has(Rx.day) ||
            d.has(Rx.unsupportedDate) || d.has(Rx.word(#"last\s+(?:month|week|year)|الشهر\s+(?:اللي\s+فات|الماضي)|الاسبوع\s+(?:اللي\s+فات|الماضي)|يوم\s+\d+"#)) {
            reason = "The expense date differs from the recording date. Review the date."
        } else if d.has(Rx.word(#"minus|negative|سالب|ناقص|ولا|او|or|either|بدل|instead|actually|اقصد|قصدي|plus|زائد|ضرب|خصم|discount|refund|cashback|استرداد"#)) ||
                    d.has(#"\d\s*[+*/×=]\s*\d"#) {
            reason = "The amount contains negation, alternatives or a correction. Review it manually."
        } else if found.isEmpty {
            reason = d.has(Rx.currencyWord) ? "The amount is unclear." : "No currency was given. Choose one explicitly."
        } else if found.count > 1 {
            reason = "Multiple amounts appear in the same sentence."
        } else if found[0].text == nil {
            reason = "Invalid amount: zero, negative, too large or an unsupported format."
        }
        if let reason {
            out.requiresReview = true
            out.reason = reason
        }
        return out
    }

    func calendarEvent(_ d: Doc, _ body: String) -> OrganizationDraft {
        let when = moment(d)
        let durations = d.all(Rx.duration)
        var cut = when.ranges + durations.map { $0.range }
        if let v = d.first(Rx.calendarVerbStart) { cut.append(v.range) }
        if let t = d.first(Rx.calendarTarget) { cut.append(t.range) }
        let title = d.removing(cut).stripped(Rx.itemLead).text
        func unclear(_ reason: String, _ start: Date? = nil) -> OrganizationDraft {
            var r = review(.calendar, d, body, reason, title: title)
            r.dueDate = start
            return r
        }
        if d.has(Rx.recurrence) { return unclear("Recurrence requires manual review.") }
        let start: Date
        switch when.found {
        case .absent: return unclear("No start date and time were given.")
        case .unclear(let reason): return unclear(reason)
        case .date(let date): start = date
        }
        guard durations.count == 1, let minutes = spanMinutes(d, durations[0]) else {
            return unclear(durations.isEmpty ? "No duration was given. Choose one explicitly." : "The duration is unclear.", start)
        }
        if hasDurationContinuation(d, durations[0]) { return unclear("The duration is incomplete or has multiple parts. Review it.", start) }
        guard !title.isEmpty, let end = calendar.date(byAdding: .minute, value: minutes, to: start) else {
            return unclear("The event title is unclear.", start)
        }
        var out = make(.calendar, title, body)
        out.dueDate = start
        out.endDate = end
        return out
    }

    func shopping(_ d: Doc, _ body: String) -> [OrganizationDraft] {
        if let add = d.first(Rx.shoppingAddStart),
           Doc(d.o(add.range)).has(Rx.w(#"هل|should\s+i|can\s+i|could\s+i|do\s+i"#)) {
            return [review(.shopping, d, body, "This asks about adding an item. Confirm the intended action.")]
        }
        if let frame = d.first(Rx.newShoppingList) { return newShopping(d, frame, body) }
        var cut: [NSRange] = []
        var collection = ""
        var kind = OrganizationKind.shopping
        if let list = listMatch(d) {
            cut.append(list.range)
            if let r = d.group(list, 1) {
                let name = Doc(d.o(r))
                if Rx.taskLists.contains(name.key) { kind = .task }
                else if !Rx.genericLists.contains(name.key) { collection = name.text }
            }
        }
        if let verb = d.first(Rx.buyVerb) { cut.append(verb.range) }
        if let verb = d.first(Rx.shoppingAddStart) { cut.append(verb.range) }
        if case .absent = moment(d).found {} else {
            return [review(kind, d, body, "This includes a date or time. Review whether you intended a reminder.")]
        }
        if d.has(Rx.currencyWord) { return [review(kind, d, body, "This includes an amount. Review whether you intended an expense.")] }
        let items = split(d.removing(cut).stripped(Rx.itemLead), Rx.itemSeparator)
        guard !items.isEmpty else { return [review(kind, d, body, "Could not identify the items.")] }
        return items.map { item in
            var out = make(kind, item, body)
            out.collection = collection
            return out
        }
    }

    private func newShopping(_ d: Doc, _ frame: NSTextCheckingResult, _ body: String) -> [OrganizationDraft] {
        let name = d.group(frame, 1).map { Doc(d.o($0)).text } ?? ""
        let rest = d.sub(from: NSMaxRange(frame.range), to: d.length)
        let tail = rest.first(Rx.purchaseTail)
        let itemText = rest.sub(from: 0, to: tail?.range.location ?? rest.length)
        func pending(_ reason: String) -> [OrganizationDraft] {
            var draft = review(.shopping, d, body, reason)
            draft.collection = name; draft.newShoppingListRequested = true
            return [draft]
        }
        guard case .absent = moment(itemText).found, !d.has(Rx.currencyWord) else {
            return pending("Review the item text or amount before creating a new shopping list.")
        }
        // Spoken wrappers and Arabic separators delimit these items; English 'and' may be a brand.
        let titles = split(itemText, Rx.repeatedItem + "|" + Rx.arabicItemSeparator)
        guard !titles.isEmpty else { return pending("The new shopping list has no clear items.") }
        var drafts = titles.map { title -> OrganizationDraft in
            var draft = make(.shopping, title, body)
            draft.collection = name; draft.newShoppingListRequested = true
            if name.isEmpty {
                draft.requiresReview = true
                draft.reason = "Name the new shopping list before saving its items. Existing lists were not changed."
            }
            return draft
        }
        if let tail {
            let plan = rest.sub(from: tail.range.location, to: rest.length)
            let when = moment(plan)
            var draft = review(.task, plan, body,
                "This is a purchase plan, not a requested notification. Review its timing separately.", title: "Buy the listed items")
            switch when.found {
            case .date(let date): draft.dueDate = date
            case .unclear(let reason): draft.reason = reason + " No notification was requested or scheduled."
            case .absent: break
            }
            drafts.append(draft)
        }
        return drafts
    }

    func task(_ d: Doc, _ body: String) -> OrganizationDraft {
        let when = moment(d)
        let base = d.removing(when.ranges)
        let project = base.first(Rx.project)
        var start = 0
        if let head = base.first(Rx.taskHead) { start = NSMaxRange(head.range) }
        else if let verb = base.first(Rx.addVerbStart) { start = NSMaxRange(verb.range) }
        let end = project?.range.location ?? base.length
        let title = base.sub(from: start, to: max(start, end)).stripped(Rx.itemLead).text
        var out = title.isEmpty ? review(.task, d, body, "The task title is unclear.") : make(.task, title, body)
        if let project, let r = base.group(project, 1) { out.collection = Doc(base.o(r)).text }
        switch when.found {
        case .absent: break
        case .date(let date): out.dueDate = date
        case .unclear(let reason):
            out.requiresReview = true
            out.reason = reason
        }
        if Rx.pronouns.contains(Doc(out.collection).key) {
            out.collection = ""
            out.requiresReview = true
            out.reason = [out.reason, "Choose the project name; the reference is unclear."].compactMap { $0 }.joined(separator: " ")
        }
        return out
    }

    func note(_ d: Doc, _ head: NSRange, _ body: String) -> OrganizationDraft {
        let after = NSMaxRange(head)
        var collection = ""
        let content: Doc
        if let colon = d.first(#"[:\n]"#, from: after) {
            let meta = d.sub(from: after, to: colon.range.location)
            if let p = meta.first(Rx.project), let r = meta.group(p, 1) { collection = Doc(meta.o(r)).text }
            content = d.sub(from: NSMaxRange(colon.range), to: d.length)
        } else {
            content = d.sub(from: after, to: d.length)
            if content.has(Rx.project) { return review(.note, d, body, "The project name is unclear. Add a colon after its name.") }
        }
        let title = shortTitle(content.stripped(Rx.noteLead).text)
        guard !title.isEmpty else { return review(.note, d, body, "The note is empty.") }
        var out = make(.note, title, body)
        out.collection = collection
        return out
    }

    func recipe(_ d: Doc, _ body: String) -> OrganizationDraft? {
        guard let head = d.first(Rx.recipeHead) else { return nil }
        let after = NSMaxRange(head.range)
        let ing = d.first(Rx.ingredientsMarker, from: after)
        let steps = d.first(Rx.stepsMarker, from: after)
        var titleEnd = d.length
        for r in [d.first(#"[:\n]"#, from: after)?.range, ing?.range, steps?.range].compactMap({ $0 }) {
            titleEnd = min(titleEnd, r.location)
        }
        let title = d.sub(from: after, to: titleEnd).text
        var out = make(.recipe, title, body)
        if let ing {
            var end = d.length
            if let steps, steps.range.location > ing.range.location { end = steps.range.location }
            out.ingredients = split(d.sub(from: NSMaxRange(ing.range), to: end), Rx.itemSeparator)
        }
        if let steps {
            var end = d.length
            if let ing, ing.range.location > steps.range.location { end = ing.range.location }
            out.steps = split(d.sub(from: NSMaxRange(steps.range), to: end), Rx.stepSeparator)
                .map { $0.replacingOccurrences(of: #"^\d+\s*[.)\-]\s*"#, with: "", options: .regularExpression) }
                .filter { !$0.isEmpty && $0.range(of: #"^\d+$"#, options: .regularExpression) == nil }
        }
        if title.isEmpty {
            out.title = shortTitle(d.text)
            out.requiresReview = true
            out.reason = "The recipe name is unclear."
        }
        return out
    }

    func fallback(_ d: Doc, _ body: String) -> OrganizationDraft {
        if d.has(Rx.imperativeStart) { return review(.note, d, body, "This command could not be understood safely. It was not executed.") }
        guard case .absent = moment(d).found, !d.has(Rx.currencyWord) else {
            return review(.note, d, body, "This includes a date or amount without a clear command. Review its type.")
        }
        let title = shortTitle(d.text)
        return title.isEmpty ? review(.note, d, body, "The text is empty.") : make(.note, title, body)
    }

    // MARK: Dates and times

    func number(_ s: String) -> Int? {
        if let v = Int(s) { return v }
        if let v = Rx.numbers[s] { return v }
        if Rx.hundreds.contains(s) { return 100 }
        if Rx.thousands.contains(s) { return 1000 }
        return nil
    }

    /// Minutes for a relative/duration match (groups: 1 count, 2 unit, 3 phrase). Day units -> nil.
    func spanMinutes(_ d: Doc, _ m: NSTextCheckingResult) -> Int? {
        if let phrase = d.gn(m, 3) { return Rx.phraseMinutes[collapse(phrase)] }
        guard let countText = d.gn(m, 1), let count = number(countText), count > 0, let unit = d.gn(m, 2) else { return nil }
        if unit.range(of: "^(?:" + Rx.minuteUnit + ")$", options: .regularExpression) != nil { return count }
        if unit.range(of: "^(?:" + Rx.hourUnit + ")$", options: .regularExpression) != nil { return count * 60 }
        return nil
    }

    func moment(_ d: Doc) -> Moment {
        let relative = d.all(Rx.relative)
        let days = d.all(Rx.day)
        let weekdays = d.all(Rx.weekday)
        let noons = d.all(Rx.noon)
        let times = d.all(Rx.time).filter { d.group($0, 1) != nil || d.group($0, 3) != nil || d.group($0, 5) != nil }
        let ranges = (relative + days + weekdays + noons + times).map { $0.range }
        func unclear(_ reason: String) -> Moment { Moment(found: .unclear(reason), ranges: ranges) }
        if d.has(Rx.unsupportedDate) { return unclear("This date format requires manual review.") }
        if d.has(Rx.pastDay) { return unclear("This date is in the past.") }
        if !relative.isEmpty {
            guard relative.count == 1, days.isEmpty, weekdays.isEmpty, noons.isEmpty, times.isEmpty else {
                return unclear("Multiple dates or times appear in the same sentence.")
            }
            guard let minutes = spanMinutes(d, relative[0]) else { return unclear("A duration in days or weeks needs a specific time.") }
            if hasDurationContinuation(d, relative[0]) { return unclear("The duration is incomplete or has multiple parts. Review it.") }
            guard let date = calendar.date(byAdding: .minute, value: minutes, to: now) else { return unclear("Could not calculate the date and time.") }
            return Moment(found: .date(date), ranges: ranges)
        }
        let dayCount = days.count + weekdays.count, timeCount = noons.count + times.count
        if dayCount == 0 && timeCount == 0 { return Moment(found: .absent, ranges: []) }
        if dayCount > 1 { return unclear("Multiple days appear in the same sentence.") }
        if timeCount > 1 { return unclear("Multiple times appear in the same sentence.") }
        if dayCount == 0 { return unclear("No day was given. Choose one explicitly.") }
        if timeCount == 0 { return unclear("A date was given without a specific time.") }

        var offset = 0
        if let m = days.first, let w = d.gn(m, 1) {
            if w.hasPrefix("بعد") || w.contains("after") { offset = 2 }
            else if w.hasPrefix("بكر") || w == "tomorrow" { offset = 1 }
        } else if let m = weekdays.first {
            if d.gn(m, 1) == "next" { return unclear("'Next' could mean this week or the following week.") }
            guard let name = d.gn(m, 2), let target = Rx.weekdayNames[name] else { return unclear("The day is unclear.") }
            offset = (target - calendar.component(.weekday, from: now) + 7) % 7
            if offset == 0 { return unclear("This weekday is today. Choose today or next week explicitly.") }
        }

        var hour = 12, minute = 0
        if let m = noons.first {
            let w = d.gn(m, 1) ?? ""
            guard w == "noon" || w == "midday" else { return unclear("Midnight is ambiguous. Specify the date and time.") }
        } else {
            switch clock(d, times[0]) {
            case .unclear(let reason): return unclear(reason)
            case .ok(let h, let mm):
                hour = h
                minute = mm
            }
        }
        guard let dayStart = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else {
            return unclear("Could not calculate the date and time.")
        }
        var parts = calendar.dateComponents([.year, .month, .day], from: dayStart)
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        guard let date = calendar.date(from: parts),
              calendar.component(.hour, from: date) == hour,
              calendar.component(.minute, from: date) == minute,
              calendar.isDate(date, inSameDayAs: dayStart) else {
            return unclear("This time does not exist on that date because the clocks change.")
        }
        guard date > now else { return unclear("The scheduled time has passed.") }
        return Moment(found: .date(date), ranges: ranges)
    }

    private func hasDurationContinuation(_ d: Doc, _ match: NSTextCheckingResult) -> Bool {
        let tail = d.sub(from: NSMaxRange(match.range), to: d.length)
        return tail.has(#"^\s*(?:and\s+|و\s*)?(?:\d|"# + Rx.numberAlt + #"|نص|ربع)(?![\p{L}])"#)
    }

    /// Time match groups: 1 prefix, 2 hour, 3 minutes, 4 fraction, 5 meridiem. Never guesses AM/PM.
    func clock(_ d: Doc, _ m: NSTextCheckingResult) -> Clock {
        let ambiguous = Clock.unclear("AM or PM was not specified. Choose it explicitly.")
        guard let hourText = d.gn(m, 2), let h = number(hourText) else { return .unclear("The hour is unclear.") }
        var minute = 0, minus = 0
        if let mmText = d.gn(m, 3) {
            guard let mm = Int(mmText), mm < 60 else { return .unclear("The minutes are invalid.") }
            minute = mm
        }
        if let fraction = d.gn(m, 4) {
            if d.group(m, 3) != nil { return .unclear("The time is contradictory.") }
            switch collapse(fraction) {
            case "ونص", "و نص", "and a half": minute = 30
            case "وربع", "و ربع": minute = 15
            case "وتلت", "و تلت": minute = 20
            case "الا ربع": minus = 15
            case "الا تلت": minus = 20
            default: return .unclear("The time is unclear.")
            }
        }
        let hour24: Int
        if let mer = d.gn(m, 5) {
            guard (1...12).contains(h) else { return .unclear("The hour conflicts with AM or PM.") }
            switch collapse(mer) {
            case "am", "a.m", "a.m.": hour24 = h == 12 ? 0 : h
            case "pm", "p.m", "p.m.": hour24 = h == 12 ? 12 : h + 12
            case "الصبح", "صباحا", "الصباح", "صباح", "ص":
                guard h <= 11 else { return ambiguous }
                hour24 = h
            case "الفجر":
                guard h <= 6 else { return ambiguous }
                hour24 = h
            case "الضهر", "الظهر", "ضهرا", "ظهرا", "بعد الضهر", "بعد الظهر":
                guard h == 12 || h <= 5 else { return ambiguous }
                hour24 = h == 12 ? 12 : h + 12
            case "العصر":
                guard h <= 6 else { return ambiguous }
                hour24 = h + 12
            case "بالليل", "بليل", "الليل":
                guard (6...11).contains(h) else { return ambiguous }
                hour24 = h + 12
            default: // مساء، المسا، المغرب، العشا، م
                guard h <= 11 else { return ambiguous }
                hour24 = h + 12
            }
        } else if (13...23).contains(h) {
            hour24 = h
        } else if h == 0 && d.group(m, 3) != nil {
            hour24 = 0
        } else {
            return ambiguous
        }
        let total = hour24 * 60 + minute - minus
        guard total >= 0, total < 24 * 60 else { return .unclear("The time is outside this day.") }
        return .ok(hour: total / 60, minute: total % 60)
    }

    // MARK: Money

    /// Only numbers attached to an explicit currency literal count as money.
    func amounts(_ d: Doc) -> [Amount] {
        var found: [Amount] = []
        func add(_ range: NSRange, _ sign: String, _ number: String?, _ cur: String) {
            guard !found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
            let valid = sign.isEmpty && number.flatMap(parseAmount) != nil
            found.append(Amount(range: range, text: valid ? number : nil, currency: currencyOf(cur)))
        }
        for m in d.all(Rx.digitAmount) { add(m.range, d.gn(m, 1) ?? "", d.gn(m, 2), d.gn(m, 3) ?? "") }
        for m in d.all(Rx.prefixAmount) { add(m.range, d.gn(m, 2) ?? "", d.gn(m, 3), d.gn(m, 1) ?? "") }
        for m in d.all(Rx.wordAmount) { add(m.range, "", d.gn(m, 1).flatMap(wordsValue).map { String($0) }, d.gn(m, 2) ?? "") }
        return found
    }

    func wordsValue(_ phrase: String) -> Int64? {
        let ns = phrase as NSString
        let tokens = regex(Rx.numberWord).matches(in: phrase, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
        guard tokens.filter({ Rx.hundreds.contains($0) }).count <= 1,
              tokens.filter({ Rx.thousands.contains($0) }).count <= 1 else { return nil }
        for pair in zip(tokens, tokens.dropFirst()) {
            guard let a = Rx.numbers[pair.0], let b = Rx.numbers[pair.1] else { continue }
            let english = pair.0.unicodeScalars.first!.value < 128 && pair.1.unicodeScalars.first!.value < 128
            let arabic = pair.0.unicodeScalars.first!.value >= 128 && pair.1.unicodeScalars.first!.value >= 128
            let tens = (20...90).contains(a) && a % 10 == 0 && (1...9).contains(b) && english
            let arabicTens = (1...9).contains(a) && (20...90).contains(b) && b % 10 == 0 && arabic
            let hundreds = a >= 100 && a % 100 == 0 && b < 100
            guard tens || arabicTens || hundreds else { return nil }
        }
        var total: Int64 = 0, current: Int64 = 0
        for m in regex(Rx.numberWord).matches(in: phrase, range: NSRange(location: 0, length: ns.length)) {
            let t = ns.substring(with: m.range)
            if Rx.hundreds.contains(t) {
                guard current <= 9 else { return nil }
                let product = max(current, 1).multipliedReportingOverflow(by: 100)
                guard !product.overflow else { return nil }
                current = product.partialValue
            } else if Rx.thousands.contains(t) {
                guard current <= 999 else { return nil }
                let product = max(current, 1).multipliedReportingOverflow(by: 1000)
                let sum = total.addingReportingOverflow(product.partialValue)
                guard !product.overflow, !sum.overflow else { return nil }
                total = sum.partialValue; current = 0
            } else if let v = Rx.numbers[t] {
                let sum = current.addingReportingOverflow(Int64(v))
                guard !sum.overflow else { return nil }
                current = sum.partialValue
            }
            else { return nil }
        }
        let sum = total.addingReportingOverflow(current)
        return !sum.overflow && sum.partialValue > 0 ? sum.partialValue : nil
    }

    func currencyOf(_ s: String) -> Currency {
        if s.range(of: "^(?:" + Rx.usd + ")$", options: .regularExpression) != nil { return .USD }
        if s.range(of: "^(?:" + Rx.eur + ")$", options: .regularExpression) != nil { return .EUR }
        return .EGP
    }

    /// One unambiguous keyword family -> that category; none or conflicting -> .other.
    func category(_ d: Doc) -> ExpenseCategory {
        let hits = Set(Rx.categories.filter { d.has(Rx.stem($0.1)) }.map { $0.0 })
        return hits.count == 1 ? hits.first! : .other
    }
}

// MARK: - Applying drafts (pure; LocalItemsModel commits the returned candidate)

enum OrganizedRecord: Equatable {
    case library(OrganizerItem)
    case expense(ExpenseItem)
    case reminder(ReminderItem)
}

private func isBlank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

func newShoppingListValidation(_ draft: OrganizationDraft, library: [OrganizerItem]) -> String? {
    guard draft.kind == .shopping, draft.newShoppingListRequested == true else { return nil }
    let name = draft.collection.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty { return "Choose a name for the new shopping list." }
    if library.contains(where: {
        $0.collection.caseInsensitiveCompare(name) == .orderedSame &&
        (draft.sourceCaptureID == nil || $0.sourceCaptureID != draft.sourceCaptureID)
    }) { return "That collection already exists. Choose a different name for the new list." }
    return nil
}

func validatedLibraryItem(_ item: OrganizerItem) throws -> OrganizerItem {
    var item = item
    item.title = try validatedTitle(item.title)
    item.collection = item.collection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard item.createdAt.timeIntervalSince1970.isFinite,
          item.dueDate?.timeIntervalSince1970.isFinite != false,
          item.endDate?.timeIntervalSince1970.isFinite != false else { throw LocalItemsError.invalidDateRange }
    if item.kind == .calendar && (item.dueDate == nil || item.endDate == nil) { throw LocalItemsError.missingDate }
    if let start = item.dueDate, let end = item.endDate, end <= start { throw LocalItemsError.invalidDateRange }
    return item
}

/// Validates a draft and builds the stored record. IDs reuse the draft ID, so the same draft
/// can never be stored twice; the draft body is kept as the raw source transcript.
func organizedRecord(from draft: OrganizationDraft, now: Date, library: [OrganizerItem] = []) throws -> OrganizedRecord {
    if let message = newShoppingListValidation(draft, library: library) {
        throw NSError(domain: "MixCapture.Shopping", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    let title = try validatedTitle(draft.title)
    switch draft.kind {
    case .reminder:
        guard let date = draft.dueDate else { throw LocalItemsError.missingDate }
        try validateFutureDate(date, now: now)
        return .reminder(ReminderItem(id: draft.id, title: title, scheduledDate: date,
                                      sourceCaptureID: draft.sourceCaptureID, sourceTranscript: draft.body))
    case .expense:
        guard let minor = parseAmount(draft.amountText) else { throw LocalItemsError.invalidAmount }
        return .expense(ExpenseItem(id: draft.id, date: draft.dueDate ?? draft.createdAt, title: title,
                                    amountMinorUnits: minor, currency: draft.currency, category: draft.category,
                                    sourceCaptureID: draft.sourceCaptureID, sourceTranscript: draft.body))
    case .note, .task, .shopping, .recipe, .calendar:
        guard let kind = OrganizerKind(rawValue: draft.kind.rawValue) else { throw LocalItemsError.notSupported }
        return .library(try validatedLibraryItem(OrganizerItem(
            id: draft.id, kind: kind, title: title, body: draft.body, collection: draft.collection,
            createdAt: draft.createdAt, dueDate: draft.dueDate, endDate: draft.endDate,
            ingredients: draft.ingredients, steps: draft.steps, sourceCaptureID: draft.sourceCaptureID)))
    }
}

private func appendingNew<T: Identifiable>(_ existing: [T], _ incoming: [T]) -> [T] where T.ID == UUID {
    var ids = Set(existing.map { $0.id })
    var out = existing
    for item in incoming where ids.insert(item.id).inserted { out.append(item) }
    return out
}

extension LocalItemsSnapshot {
    func receipt(for sourceID: UUID) -> OrganizationReceipt? {
        organizationReceipts?.first { $0.id == sourceID }
    }

    mutating func insert(_ record: OrganizedRecord) {
        switch record {
        case .library(let item): library = (library ?? []) + [item]
        case .expense(let item): expenses.append(item)
        case .reminder(let item): reminders.append(item)
        }
    }

    func receiptLine(for sourceID: UUID) -> (summary: String, status: OrganizationReceipt.Status) {
        let saved = (library ?? []).filter { $0.sourceCaptureID == sourceID }.count
            + expenses.filter { $0.sourceCaptureID == sourceID }.count
            + reminders.filter { $0.sourceCaptureID == sourceID }.count
        let pending = (reviewQueue ?? []).filter { $0.sourceCaptureID == sourceID }.count
        return ("Saved: \(saved) · For review: \(pending)", pending > 0 ? .review : .applied)
    }

    /// One candidate with every saved item, review draft and the receipt. `nil` when the source
    /// already has a receipt (applied, in review or undone), so retries never duplicate.
    func applyingOrganization(_ drafts: [OrganizationDraft], sourceID: UUID, now: Date)
        -> (snapshot: LocalItemsSnapshot, receipt: OrganizationReceipt, reminderIDs: [UUID])? {
        guard receipt(for: sourceID) == nil else { return nil }
        var next = self
        let existingSource = (library ?? []).contains { $0.sourceCaptureID == sourceID } ||
            expenses.contains { $0.sourceCaptureID == sourceID } || reminders.contains { $0.sourceCaptureID == sourceID } ||
            (reviewQueue ?? []).contains { $0.sourceCaptureID == sourceID }
        if existingSource {
            let receipt = OrganizationReceipt(id: sourceID, createdAt: now,
                summary: "This source already has saved items. No duplicates were added.", status: receiptLine(for: sourceID).status,
                originalText: drafts.first?.body)
            next.organizationReceipts = (next.organizationReceipts ?? []) + [receipt]
            return (next, receipt, [])
        }
        var reminderIDs: [UUID] = []
        for var draft in drafts {
            draft.sourceCaptureID = sourceID
            if !draft.requiresReview {
                do {
                    let record = try organizedRecord(from: draft, now: now, library: next.library ?? [])
                    if case .reminder(let item) = record { reminderIDs.append(item.id) }
                    next.insert(record)
                    continue
                } catch {
                    draft.requiresReview = true
                    draft.reason = error.localizedDescription
                }
            }
            next.reviewQueue = (next.reviewQueue ?? []) + [draft]
        }
        let line = next.receiptLine(for: sourceID)
        let receipt = OrganizationReceipt(id: sourceID, createdAt: now, summary: line.summary, status: line.status,
                                          originalText: drafts.first?.body)
        next.organizationReceipts = (next.organizationReceipts ?? []) + [receipt]
        return (next, receipt, reminderIDs)
    }

    /// Applies a (possibly UI-edited) queued draft. Body and source linkage come from the stored draft.
    func applyingReview(_ edited: OrganizationDraft, now: Date) throws -> (snapshot: LocalItemsSnapshot, record: OrganizedRecord) {
        guard var queue = reviewQueue, let index = queue.firstIndex(where: { $0.id == edited.id }) else {
            throw LocalItemsError.notFound
        }
        let stored = queue[index]
        guard !(library ?? []).contains(where: { $0.id == stored.id }),
              !expenses.contains(where: { $0.id == stored.id }),
              !reminders.contains(where: { $0.id == stored.id }) else { throw LocalItemsError.notFound }
        var draft = edited
        draft.body = stored.body
        draft.sourceCaptureID = stored.sourceCaptureID
        draft.createdAt = stored.createdAt
        draft.newShoppingListRequested = stored.newShoppingListRequested
        let record = try organizedRecord(from: draft, now: now, library: library ?? [])
        queue.remove(at: index)
        if draft.kind == .shopping, draft.newShoppingListRequested == true, let source = draft.sourceCaptureID {
            for i in queue.indices where queue[i].kind == .shopping && queue[i].newShoppingListRequested == true &&
                queue[i].sourceCaptureID == source && queue[i].collection == stored.collection {
                queue[i].collection = draft.collection.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var next = self
        next.reviewQueue = queue
        next.insert(record)
        if let source = stored.sourceCaptureID, var receipts = next.organizationReceipts,
           let r = receipts.firstIndex(where: { $0.id == source }), receipts[r].status != .undone {
            let line = next.receiptLine(for: source)
            receipts[r].summary = line.summary
            receipts[r].status = line.status
            next.organizationReceipts = receipts
        }
        return (next, record)
    }

    /// Removes everything linked to the source and keeps its receipt as `.undone`.
    func preparingCalendarUndo(sourceID: UUID) -> LocalItemsSnapshot {
        var next = self
        for index in (next.library ?? []).indices {
            guard let item = next.library?[index], item.kind == .calendar, item.sourceCaptureID == sourceID,
                  let id = item.externalCalendarID, !id.hasPrefix("undo:") else { continue }
            next.library?[index].externalCalendarID = "undo:\(id)"
        }
        return next
    }

    func undoingOrganization(sourceID: UUID) throws -> (snapshot: LocalItemsSnapshot, removedReminderIDs: [UUID]) {
        guard var receipts = organizationReceipts, let index = receipts.firstIndex(where: { $0.id == sourceID }) else {
            throw LocalItemsError.notFound
        }
        var next = self
        let removed = reminders.filter { $0.sourceCaptureID == sourceID }.map { $0.id }
        next.reminders.removeAll { $0.sourceCaptureID == sourceID }
        next.expenses.removeAll { $0.sourceCaptureID == sourceID }
        next.library = library?.filter { $0.sourceCaptureID != sourceID }
        next.reviewQueue = reviewQueue?.filter { $0.sourceCaptureID != sourceID }
        receipts[index].status = .undone
        receipts[index].summary = "Undone. This source will not be organized again automatically."
        next.organizationReceipts = receipts
        return (next, removed)
    }

    /// Additive by UUID; existing records win on collision. Rejects the whole import if any record
    /// is invalid. Imported reminders are not scheduled on this device, so they become pending.
    func merging(_ incoming: LocalItemsSnapshot) throws -> LocalItemsSnapshot {
        let occupied = Set(expenses.map(\.id) + reminders.map(\.id) +
                           (library ?? []).map(\.id) + (reviewQueue ?? []).map(\.id))
        func allowed(_ sourceID: UUID?) -> Bool {
            guard let sourceID else { return true }
            return receipt(for: sourceID)?.status != .undone
        }
        func unique<T: Identifiable>(_ rows: [T]) -> Bool where T.ID == UUID {
            Set(rows.map(\.id)).count == rows.count
        }
        guard unique(incoming.expenses), unique(incoming.reminders), unique(incoming.library ?? []),
              unique(incoming.reviewQueue ?? []), unique(incoming.organizationReceipts ?? []) else {
            throw LocalItemsError.invalidBackup("Duplicate identifiers")
        }
        let incomingIDs = incoming.expenses.map(\.id) + incoming.reminders.map(\.id) +
            (incoming.library ?? []).map(\.id) + (incoming.reviewQueue ?? []).map(\.id)
        guard Set(incomingIDs).count == incomingIDs.count else {
            throw LocalItemsError.invalidBackup("An identifier is shared by multiple items")
        }
        for item in incoming.expenses where item.amountMinorUnits <= 0 || isBlank(item.title) {
            throw LocalItemsError.invalidBackup("Expense \(item.id.uuidString)")
        }
        for item in incoming.reminders where isBlank(item.title) {
            throw LocalItemsError.invalidBackup("Reminder \(item.id.uuidString)")
        }
        guard incoming.expenses.allSatisfy({ $0.date.timeIntervalSince1970.isFinite }),
              incoming.reminders.allSatisfy({ $0.scheduledDate.timeIntervalSince1970.isFinite }),
              (incoming.reviewQueue ?? []).allSatisfy({ $0.createdAt.timeIntervalSince1970.isFinite &&
                  $0.dueDate?.timeIntervalSince1970.isFinite != false && $0.endDate?.timeIntervalSince1970.isFinite != false }),
              (incoming.organizationReceipts ?? []).allSatisfy({ $0.createdAt.timeIntervalSince1970.isFinite }) else {
            throw LocalItemsError.invalidBackup("Invalid date")
        }
        for item in incoming.library ?? [] {
            do { _ = try validatedLibraryItem(item) } catch {
                throw LocalItemsError.invalidBackup("\(item.id.uuidString): \(error.localizedDescription)")
            }
        }
        for draft in incoming.reviewQueue ?? [] where isBlank(draft.title) {
            throw LocalItemsError.invalidBackup("Review item \(draft.id.uuidString)")
        }
        var next = self
        next.expenses = appendingNew(expenses, incoming.expenses.filter { !occupied.contains($0.id) && allowed($0.sourceCaptureID) })
        next.reminders = appendingNew(reminders, incoming.reminders.filter { !occupied.contains($0.id) && allowed($0.sourceCaptureID) }.map { reminder -> ReminderItem in
            var copy = reminder
            copy.automaticSchedulingEligible = false
            if copy.status != .completed {
                copy.status = .pending
                copy.scheduleError = "Imported from a backup. Not scheduled on this device."
            }
            return copy
        })
        if library != nil || incoming.library != nil {
            next.library = appendingNew(library ?? [], (incoming.library ?? []).filter { !occupied.contains($0.id) && allowed($0.sourceCaptureID) }.map { item in
                var copy = item
                copy.externalCalendarID = nil
                copy.calendarSyncEligible = false
                return copy
            })
        }
        if reviewQueue != nil || incoming.reviewQueue != nil {
            next.reviewQueue = appendingNew(reviewQueue ?? [], (incoming.reviewQueue ?? []).filter { !occupied.contains($0.id) && allowed($0.sourceCaptureID) })
        }
        if organizationReceipts != nil || incoming.organizationReceipts != nil {
            next.organizationReceipts = appendingNew(organizationReceipts ?? [], incoming.organizationReceipts ?? [])
        }
        return next
    }
}
