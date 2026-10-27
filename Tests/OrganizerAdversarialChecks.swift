import Foundation

/// Run with LocalItems.swift + Organizer.swift; exercises the production parser only.
@main
struct OrganizerAdversarialChecks {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Cairo")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!
        let tomorrowAtTen = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 10))!
        var failures: [String] = []
        var cases = 0

        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func parse(_ text: String) -> [OrganizationDraft] {
            cases += 1
            let drafts = OrganizerParser.parse(text, now: now, calendar: calendar)
            check(!drafts.isEmpty, "Input was silently discarded: \(text)")
            // These cases contain one source command, including punctuation and mixed script.
            check(drafts.allSatisfy { $0.body == text }, "Original source changed: \(text)")
            return drafts
        }
        func automatic(_ text: String, kind: OrganizationKind, amount: Int64? = nil,
                       due: Date? = nil, collection: String? = nil) {
            let drafts = parse(text)
            check(drafts.count == 1, "Expected one clear command: \(text)")
            guard drafts.count == 1, let draft = drafts.first else { return }
            check(!draft.requiresReview && draft.kind == kind, "Clear command did not auto-route to \(kind): \(text)")
            if let amount {
                check(parseAmount(draft.amountText) == amount, "Wrong money amount: \(text) -> \(draft.amountText)")
                check(draft.currency == .EGP, "Wrong currency: \(text)")
            }
            if let due {
                check(draft.dueDate.map { abs($0.timeIntervalSince(due)) < 1 } == true,
                      "Wrong reminder date: \(text) -> \(String(describing: draft.dueDate))")
            }
            if let collection {
                check(draft.collection == collection, "Project name changed: \(text) -> \(draft.collection)")
            }
        }
        func review(_ text: String) {
            let drafts = parse(text)
            check(drafts.allSatisfy(\.requiresReview), "Unsafe automatic interpretation: \(text)")
        }

        // The same natural lead-in must preserve ALL supported actions and compound payloads,
        // rather than being patched into the shopping grammar alone. No real side effects.
        let commands = [
            "ضيف red marker لقائمة المشتريات.",
            "دفعت 50 جنيه قهوة",
            "فكرني بكرة 10 AM أبعت التقرير",
            "ضيف مهمة review budget لمشروع Home",
            "حط في التقويم قراءة كتاب بكرة الساعة عشرة الصبح لمدة 30 دقيقة",
            "ملاحظة لمشروع Home: راجع API v2",
            "احفظ وصفة شاي: المكونات: ماء؛ الخطوات: سخن الماء",
            "ضيف لبن لقائمة المشتريات وفكرني أجيبه بكرة 5 PM",
            "دفعت 50 جنيه قهوة؛ ضيف لبن لقائمة المشتريات",
            "فكرني بكرة 5 PM أجيب لبن؛ ضيف لبن لقائمة المشتريات",
            "هل اضيف لبن لقائمة المشتريات",
            "لو ضفت لبن لقائمة المشتريات",
            "if I add milk to shopping list Groceries",
            "مش عايز اضيف لبن لقائمة المشتريات",
            "note: the shopping list is in the drawer.",
            "\"عايز احط red marker في ال shopping list\"",
        ]
        func semantic(_ drafts: [OrganizationDraft]) -> [OrganizationDraft] {
            drafts.map { original in
                var draft = original
                draft.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                draft.body = "" // only IDs and the verbatim source differ across paraphrases
                return draft
            }
        }
        for command in commands {
            let expected = parse(command)
            for prefix in ["يعني ", "يعني، ", "يعني: ", "يعني،", "يعني يعني "] {
                let actual = parse(prefix + command)
                check(semantic(actual) == semantic(expected),
                      "Spoken prefix changed action fields, composition or safety: \(prefix + command)")
            }
        }
        for command in commands.suffix(6).prefix(4) { review("يعني، " + command) }
        let spokenCompound = parse("يعني ضيف لبن لقائمة المشتريات وفكرني أجيبه بكرة 5 PM")
        check(spokenCompound.count == 2 && spokenCompound.map(\.kind) == [.shopping, .reminder] &&
              spokenCompound.allSatisfy { !$0.requiresReview } && spokenCompound[0].title == "لبن" &&
              spokenCompound[1].dueDate == calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 17)),
              "A shopping request and an explicit reminder remain two independent actions")
        for connector in [" وفكرني ", " و فكرني ", "،وفكرني ", "، و فكرني "] {
            let drafts = parse("ضيف لبن لقائمة المشتريات" + connector + "أجيبه بكرة 5 PM")
            check(semantic(drafts) == semantic(spokenCompound),
                  "Connector spacing and commas must preserve both independent actions")
        }
        let compoundText = "ضيف لبن لقائمة المشتريات وفكرني أجيبه بكرة 5 PM"
        for (open, close) in [("«", "»"), ("“", "”"), ("\"", "\"")] {
            let wrapped = open + compoundText + close + "."
            let drafts = parse(wrapped)
            check(semantic(drafts) == semantic(spokenCompound),
                  "Whole-input quotation formatting must preserve compound action fields")
            let saved = LocalItemsSnapshot().applyingOrganization(drafts, sourceID: UUID(), now: now)!.snapshot
            check(saved.library?.count == 1 && saved.library?.first?.kind == .shopping &&
                  saved.library?.first?.body == wrapped && saved.reminders.count == 1 &&
                  saved.reminders.first?.sourceTranscript == wrapped && (saved.reviewQueue ?? []).isEmpty,
                  "A pasted quoted command stores Shopping plus Reminder with the verbatim source")
            review(open + "هل أضيف لبن لقائمة المشتريات" + close)
            review(open + "ضيف لبن لقائمة المشتريات؟" + close)
            review(open + "متضيفش لبن لقائمة المشتريات" + close)
            let explicitNote = parse(open + "note: put milk on the shopping list" + close)
            check(explicitNote.count == 1 && explicitNote[0].kind == .note,
                  "An explicit note about a quoted command stays a note")
        }
        let purchaseAndExpense = parse("ضيف لبن لقائمة المشتريات، و سجل مصروف 50 جنيه قهوة")
        check(purchaseAndExpense.count == 2 && purchaseAndExpense.map(\.kind) == [.shopping, .expense] &&
              purchaseAndExpense.allSatisfy { !$0.requiresReview } && purchaseAndExpense[0].title == "لبن" &&
              parseAmount(purchaseAndExpense[1].amountText) == 5000,
              "The shared spaced connector also separates explicit expense commands")
        review("ضيف لبن لقائمة المشتريات، و متفكرنيش أجيبه بكرة 5 PM")
        review("ضيف لبن لقائمة المشتريات، و فكرني أجيبه بكرة 5 PM؟")
        for prefix in ["", "يعني، "] {
            for recipe in ["Save a recipe for apple juice, don't save this",
                           "recipe apple juice. Cancel this.",
                           "احفظ وصفة شاي؟"] {
                let drafts = parse(prefix + recipe)
                check(drafts.count == 1 && drafts[0].kind == .recipe && drafts[0].requiresReview,
                      "Recipe framing must not bypass cancellation or question checks")
            }
        }

        // Clear phrases explicitly promised by the implementation brief.
        automatic("فكرني بعد 10 دقايق أكلم أحمد", kind: .reminder, due: now.addingTimeInterval(600))
        automatic("remind me in 20 minutes to call Sam", kind: .reminder, due: now.addingTimeInterval(1200))
        automatic("فكرني بعد نص ساعة أبعت review", kind: .reminder, due: now.addingTimeInterval(1800))
        automatic("فكرني بعد ربع ساعة أكلم Sam", kind: .reminder, due: now.addingTimeInterval(900))
        automatic("فكرني بكرة الساعة عشرة الصبح أبعت review", kind: .reminder, due: tomorrowAtTen)
        automatic("remind me tomorrow at 10 AM to review budget", kind: .reminder, due: tomorrowAtTen)
        automatic("schedule a meeting tomorrow at 10 AM for 30 minutes", kind: .calendar, due: tomorrowAtTen)
        review("ضيف task أراجع النتائج للـ project ده")
        review("ساعدني أطور فكرة خدمة لترتيب أدوات المكتب")
        review("ساعدني develop فكرة لعبة تعليمية")
        review("Help me develop an app for organizing public reading lists")
        review("غيّر deadline بتاع الـ task ده لبكرة الصبح في نفس الـ project")
        review("للـ الخبز هل أضيف milk لقائمة Groceries")
        let indirectListMention = parse("For banana bread you can add milk to the shopping list Groceries")
        check(indirectListMention.allSatisfy { $0.kind == .note }, "Descriptive English purpose text is not an imperative add request")
        let calendarPurchase = parse("Add a calendar to shopping list Office")
        check(calendarPurchase.count == 1 && calendarPurchase.first?.kind == .shopping && calendarPurchase.first?.requiresReview == false,
              "A calendar item on a shopping list is a purchase, not a calendar event")
        let twoLists = parse("اعمل list جديدة أحط فيها تفاح؛ اعمل list جديدة أحط فيها ورق")
        check(twoLists.count == 1 && twoLists.allSatisfy(\.requiresReview), "Two unnamed new lists cannot silently share a collection")
        review("اعمل list جديدة اسمها Pantry أحط فيها تفاح وبعدين اعمل list جديدة اسمها Office أحط فيها ورق")
        let quotedRequest = parse("note: Help me develop a puzzle is a phrase to remember")
        check(quotedRequest.count == 1 && quotedRequest.first?.kind == .note && quotedRequest.first?.requiresReview == false,
              "Explicit note framing is preserved around a quoted development request")
        automatic("حط في التقويم قراءة كتاب بكرة الساعة عشرة الصبح لمدة 30 دقيقة", kind: .calendar, due: tomorrowAtTen)
        automatic("Add to calendar practice tomorrow at 10 AM for 30 minutes", kind: .calendar, due: tomorrowAtTen)
        check(parse("احفظ ملاحظة: حط في التقويم وقت للقراءة").allSatisfy { $0.kind == .note },
              "An explicit note frame must not become a calendar event")
        automatic("دفعت ١٢٠٫٥٠ جنيه في Uber", kind: .expense, amount: 12050)
        automatic("paid 120.50 EGP for Uber", kind: .expense, amount: 12050)
        automatic("سجل مصروف خمسين جنيه قهوة", kind: .expense, amount: 5000)
        automatic("دفعت مية وخمسين جنيه في Uber", kind: .expense, amount: 15000)
        automatic("دفعت مئة و عشرين جنيه على القهوة", kind: .expense, amount: 12000)
        automatic("دفعت مئة وعشرين جنيه على القهوة", kind: .expense, amount: 12000)
        automatic("دفعت مائة وعشرين جنيه على القهوة", kind: .expense, amount: 12000)
        automatic("paid one hundred twenty five EGP for Uber", kind: .expense, amount: 12500)
        automatic("ضيف مهمة review budget لمشروع Home", kind: .task, collection: "Home")
        automatic("add a task to review budget for project Home", kind: .task, collection: "Home")
        automatic("ملاحظة لمشروع Home: راجع API v2 مع أحمد", kind: .note, collection: "Home")

        let shopping = parse("add milk and eggs to shopping list Groceries")
        check(shopping.count == 2 && shopping.allSatisfy { !$0.requiresReview && $0.kind == .shopping && $0.collection == "Groceries" },
              "Clear shopping command must create two entries in the named list")
        check(shopping.contains { $0.title.localizedCaseInsensitiveContains("milk") } &&
              shopping.contains { $0.title.localizedCaseInsensitiveContains("eggs") }, "Shopping lost an explicit item")

        let recipe = parse("وصفة مكرونة: المكونات مكرونة وطماطم. الطريقة اسلق المكرونة ثم ضيف الطماطم")
        check(recipe.count == 1 && recipe.allSatisfy { !$0.requiresReview && $0.kind == .recipe },
              "Recipe instructions must stay in a recipe, not become separate actions")
        let englishRecipe = parse("recipe Lentil soup: ingredients lentils and onion. steps boil the lentils then blend")
        let savedRecipe = parse("Save a recipe for Oat porridge. Ingredients: oats and milk. Steps: simmer then stir.")
        check(savedRecipe.count == 1 && savedRecipe.first?.kind == .recipe && savedRecipe.first?.requiresReview == false
              && savedRecipe.first?.title == "Oat porridge", "A natural English recipe request retains its recipe type and name")
        check(englishRecipe.count == 1 && englishRecipe.first?.kind == .recipe && englishRecipe.first?.requiresReview == false,
              "English recipe must organize automatically as one recipe")
        check(englishRecipe.first?.title == "Lentil soup" && englishRecipe.first?.ingredients == ["lentils", "onion"] &&
              englishRecipe.first?.steps == ["boil the lentils", "blend"],
              "English recipe must retain its spoken name, ingredients and steps")

        // Negation/correction, competing values, and missing information must not execute.
        for text in [
            "don't record an expense of 50 EGP for coffee",
            "متسجلش مصروف 50 جنيه قهوة",
            "مش عايز تذكير بعد 10 دقايق أكلم أحمد",
            "فكرني بكرة الساعة 10 الصبح، لا مش بكرة بعد بكرة",
            "دفعت 50 دولار أو 120 جنيه في Uber",
            "remind me tomorrow at 5 to call Sam",
            "فكرني بكرة الساعة خمسة أكلم أحمد",
            "فكرني كل يوم الساعة 10 الصبح آخد الدوا",
            "remind me yesterday at 10 AM to call Sam",
            "حط اجتماع design meeting بكرة الساعة 3 PM",
            "paid -50 EGP for coffee",
            "paid −50 EGP for coffee",
            "paid –50 EGP for coffee",
            "paid 50+20 EGP for coffee",
            "دفعت عشرين زائد خمسين جنيه",
            "paid minus 50 EGP for coffee",
            "paid five fifty EGP for coffee",
            "paid fifty fifty EGP for coffee",
            "paid one hundred one hundred EGP for coffee",
            "هل دفعت 50 جنيه في Uber؟",
            "if I paid 50 EGP for coffee",
            "هو أنا دفعت 50 جنيه في Uber",
            "maybe I paid 50 EGP for coffee",
            "paid 50 EGP for coffee?",
            "paid 50 EGP for Uber at 10 AM",
            "paid 50 EGP for Uber in 20 minutes",
            "دفعت 50 ولا 120 جنيه في Uber",
            "paid 50 EGP for coffee; no cancel that",
            "paid 0 EGP for coffee",
            "paid 120.501 EGP for Uber",
            "remind me in 1 hour and 20 to call Sam"
        ] { review(text) }

        // Supporting a compound duration is optional; silently truncating it is unsafe.
        let compound = parse("فكرني بعد ساعة ونص أكلم أحمد")
        check(compound.allSatisfy { $0.requiresReview || ($0.kind == .reminder &&
            $0.dueDate.map { abs($0.timeIntervalSince(now) - 5400) < 1 } == true) },
              "Compound duration was truncated instead of reviewed or interpreted as 90 minutes")

        // Numeric titles must never win over a currency-qualified amount.
        let book = parse("اشتريت كتاب 1984 بخمسين جنيه")
        check(book.allSatisfy { $0.requiresReview || ($0.kind == .expense &&
            $0.currency == .EGP && parseAmount($0.amountText) == 5000) },
              "A number in a book title became the expense amount")

        // The schema can represent an exact expense date, not an unspecified historical month.
        let historical = parse("paid 50 EGP for coffee last month")
        check(historical.allSatisfy(\.requiresReview),
              "An unresolved historical expense date silently became today's expense")

        for failure in failures { print("FAIL: \(failure)") }
        if !failures.isEmpty {
            print("OrganizerAdversarialChecks: \(failures.count) failures across \(cases) source cases")
            exit(1)
        }
        print("OrganizerAdversarialChecks OK (\(cases) source cases)")
    }
}
