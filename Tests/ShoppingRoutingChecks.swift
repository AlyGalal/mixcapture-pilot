import Foundation

/// Synthetic text only. Compile with LocalItems.swift and Organizer.swift; no native side effects.
@main
struct ShoppingRoutingChecks {
    static var failures = 0
    static var cases = 0
    static func check(_ value: Bool, _ message: String) {
        if !value { failures += 1; print("FAIL: \(message)") }
    }
    static func rejects(_ message: String, _ operation: () throws -> Void) {
        do { try operation(); check(false, message) } catch {}
    }

    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Cairo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!
        let tomorrowAtFivePM = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 17))!
        func parse(_ text: String) -> [OrganizationDraft] {
            cases += 1
            let drafts = OrganizerParser.parse(text, now: now, calendar: calendar)
            check(!drafts.isEmpty && drafts.allSatisfy { $0.body == text }, "Original source must survive: \(text)")
            return drafts
        }
        func item(_ text: String, _ title: String) {
            let drafts = parse(text)
            check(drafts.count == 1 && drafts[0].kind == .shopping && drafts[0].title == title &&
                  drafts[0].collection == "Groceries" && !drafts[0].requiresReview, "Mixed list routing: \(text)")
        }
        // Speech engines add sentence punctuation; this must not change an unnamed destination.
        for command in ["عايز احط red marker في ال shopping list", "ضيف red marker لقائمة المشتريات"] {
            for ending in [".", ",", "،", "!", ":", "؛", "…"] {
                let drafts = parse(command + ending)
                check(drafts.count == 1 && drafts[0].kind == .shopping && drafts[0].title == "red marker" &&
                      drafts[0].collection.isEmpty && !drafts[0].requiresReview,
                      "Sentence punctuation changed shopping routing: \(command + ending)")
            }
        }
        for name in ["C#", "C++", "A_B"] {
            let drafts = parse("Add red marker to shopping list " + name)
            check(drafts.count == 1 && drafts[0].collection == name && drafts[0].kind == .shopping,
                  "Meaningful collection-name characters must survive: \(name)")
        }
        for ending in ["?", "؟", "?!", "؟.", "?\"", "?)."] {
            let drafts = parse("Add red marker to shopping list Groceries" + ending)
            check(drafts.allSatisfy(\.requiresReview), "A question ending must not create shopping items: \(ending)")
        }
        let spokenSource = "عايز احط red marker في ال shopping list."
        let spoken = parse(spokenSource)
        let spokenSnapshot = LocalItemsSnapshot().applyingOrganization(spoken, sourceID: UUID(), now: now)!.snapshot
        let restored = try JSONDecoder().decode(LocalItemsSnapshot.self, from: JSONEncoder().encode(spokenSnapshot))
        check(restored.library?.count == 1 && restored.library?.first?.kind == .shopping &&
              restored.library?.first?.body == spokenSource && (restored.reviewQueue ?? []).isEmpty,
              "The spoken-punctuation path stores and reloads Shopping with the untouched source")
        item("عايز أحط blue notebook في ال shopping list Groceries", "blue notebook")
        item("عايزة أضيف Lego City bus للـshoppinglist Groceries", "Lego City bus")
        item("عاوز أحط apple juice فيالـshopping list Groceries", "apple juice")
        item("ضيف blue notebook في shoppinglistة Groceries", "blue notebook")
        let englishDesire = parse("I want to add blue notebook to my shopping list")
        check(englishDesire.count == 1 && englishDesire[0].kind == .shopping &&
              englishDesire[0].title == "blue notebook" && !englishDesire[0].requiresReview,
              "An English desire-add request is a shopping command, not a note")
        let descriptive = parse("I saw a shopping list in a notebook.")
        check(descriptive.count == 1 && descriptive[0].kind == .note, "A descriptive list mention is not an add command")
        let note = parse("note: the shopping list is in the drawer.")
        check(note.count == 1 && note[0].kind == .note, "An explicit note keeps its type")
        for text in ["مش عايز أحط blue notebook في الshopping list Groceries",
                     "هل أضيف apple juice للـshoppinglist Groceries؟"] {
            check(parse(text).allSatisfy(\.requiresReview), "Negations and questions never add items")
        }
        let legacy = parse("add milk and eggs to shopping list Groceries")
        check(legacy.map(\.title) == ["milk", "eggs"] && legacy.allSatisfy {
            $0.kind == .shopping && $0.collection == "Groceries" && !$0.requiresReview
        }, "Existing English list splitting remains intact")
        for text in ["للـ banana bread ضيف 3 bananas و200 grams flour وعلبة baking powder لقائمة Baking",
                     "For banana bread, add 3 bananas و200 grams flour وعلبة baking powder to shopping list Baking"] {
            let baking = parse(text)
            check(baking.map(\.title) == ["3 bananas", "200 grams flour", "علبة baking powder"] && baking.allSatisfy {
                $0.kind == .shopping && $0.collection == "Baking" && !$0.requiresReview
            }, "A purpose-framed add command keeps all three items and removes only its shared wrapper")
        }
        let purposeNote = parse("For banana bread, the shopping list has flour.")
        check(purposeNote.count == 1 && purposeNote[0].kind == .note,
              "A purpose and list mention without an add command remains a note")

        let unnamedText = "عايز ابتدي أعمل list جديدة أحط فيها blue notebook وLego City bus وأحط فيها apple juice"
        let unnamed = parse(unnamedText)
        let titles = ["blue notebook", "Lego City bus", "apple juice"]
        check(unnamed.map(\.title) == titles && unnamed.allSatisfy {
            $0.kind == .shopping && $0.requiresReview && $0.collection.isEmpty && $0.newShoppingListRequested == true
        }, "A new unnamed list yields exact pending items, not an implicit merge")
        for input in ["عايز أعمل list جديدة، أحط فيها blue notebook وأحط فيها apple juice",
                      "اعمل list جديدة اسمها Market: أحط فيها: blue notebook وأحط فيها apple juice"] {
            let punctuated = parse(input)
            check(punctuated.map(\.title) == ["blue notebook", "apple juice"] && punctuated.allSatisfy { $0.kind == .shopping },
                  "Speech punctuation around a list header keeps shopping routing")
        }
        let hybrid = parse("عايز أعمل listة جديدة أحط فيها blue notebook")
        check(hybrid.count == 1 && hybrid[0].title == "blue notebook" && hybrid[0].requiresReview &&
              hybrid[0].newShoppingListRequested == true, "Hybrid feminine list noun is recognized")
        let namedText = "اعمل list جديدة اسمها Weekend أحط فيها blue notebook وأحط فيها Lego City bus"
        let named = parse(namedText)
        check(named.map(\.title) == Array(titles.prefix(2)) && named.allSatisfy {
            $0.kind == .shopping && !$0.requiresReview && $0.collection == "Weekend" && $0.newShoppingListRequested == true
        }, "An explicit new list name is preserved for state validation")
        let internalAnd = parse("اعمل list جديدة اسمها Weekend أحط فيها Ink and Paper notebook وأحط فيها apple juice")
        check(internalAnd.map(\.title) == ["Ink and Paper notebook", "apple juice"],
              "Spoken item wrappers preserve English internal and")

        for (tail, expectedDate) in [
            ("، كل ده عايز أنزل أشتريه بكرة الساعة خمسة", Date?.none),
            ("، كل ده عايز أنزل أشتريه بكرة الساعة 5 PM", Optional(tomorrowAtFivePM)),
            ("، كل ده هشتريه بكرة", Date?.none)
        ] {
            let drafts = parse(unnamedText + tail)
            check(drafts.filter { $0.kind == .shopping }.map(\.title) == titles,
                  "Purchase timing never becomes an item or erases item names")
            let plans = drafts.filter { $0.kind == .task }
            check(drafts.count == 4 && plans.count == 1 && drafts.allSatisfy(\.requiresReview) &&
                  plans[0].dueDate == expectedDate, "Purchase plan timing is retained or clarified without guessing")
            check(!drafts.contains { $0.kind == .reminder || $0.kind == .calendar }, "A purchase time does not authorize notifications")
        }
        let explicit = parse("اعمل list جديدة اسمها Weekend أحط فيها blue notebook وفكرني أشتري blue notebook بكرة 5 PM")
        let reminders = explicit.filter { $0.kind == .reminder }
        check(explicit.count == 2 && reminders.count == 1 && reminders[0].dueDate == tomorrowAtFivePM &&
              !reminders[0].requiresReview, "An explicit reminder request retains its own route")
        let unscopedTime = parse("اعمل list جديدة اسمها Weekend أحط فيها blue notebook بكرة 5 PM")
        check(unscopedTime.allSatisfy(\.requiresReview) && !unscopedTime.contains { $0.kind == .reminder },
              "Unscoped dates still hit the review gate")
        check(parse("اعمل list جديدة اسمها Weekend أحط فيها blue notebook ومتحطش apple juice").allSatisfy(\.requiresReview),
              "A later negation blocks the whole new-list command")

        // Exercise the same pure transition used by LocalItemsModel, including foreign-list collisions.
        let source = UUID()
        let queued = LocalItemsSnapshot().applyingOrganization(unnamed, sourceID: source, now: now)!.snapshot
        check((queued.library ?? []).isEmpty && queued.reviewQueue?.count == 3,
              "Unnamed list creates no stored shopping items")
        rejects("Shared record validation must reject a missing new list name") {
            _ = try organizedRecord(from: unnamed[0], now: now)
        }
        check(newShoppingListValidation(unnamed[0], library: []) != nil, "UI and state use the same list-name validation")
        let roundtrip = try JSONDecoder().decode([OrganizationDraft].self, from: JSONEncoder().encode(unnamed))
        check(roundtrip == unnamed, "Pending new-list metadata survives relaunch")
        let fresh = LocalItemsSnapshot().applyingOrganization(named, sourceID: UUID(), now: now)!.snapshot
        check(fresh.library?.count == 2 && (fresh.reviewQueue ?? []).isEmpty,
              "A noncolliding explicitly named new list may save atomically")
        var occupied = LocalItemsSnapshot()
        occupied.library = [OrganizerItem(kind: .shopping, title: "Existing item", body: "Synthetic existing source",
                                          collection: "Weekend", sourceCaptureID: UUID())]
        let blocked = occupied.applyingOrganization(named, sourceID: source, now: now)!.snapshot
        check(blocked.library == occupied.library && blocked.reviewQueue?.count == 2,
              "New list name collision never merges into a foreign collection")
        var reviewed = blocked.reviewQueue![0]
        reviewed.newShoppingListRequested = false
        rejects("Editing a draft cannot clear its stored new-list validation flag") {
            _ = try blocked.applyingReview(reviewed, now: now)
        }
        reviewed.collection = "Fresh errands"
        let first = try blocked.applyingReview(reviewed, now: now)
        check(first.snapshot.reviewQueue?.first?.collection == "Fresh errands",
              "Naming the list updates only its pending sibling names")
        let second = try first.snapshot.applyingReview(first.snapshot.reviewQueue![0], now: now)
        check(second.snapshot.library?.filter { $0.collection == "Fresh errands" }.count == 2 &&
              second.snapshot.library?.first == occupied.library?.first && second.snapshot.reviewQueue?.isEmpty == true,
              "Same-source siblings share the new name while the existing list stays unchanged")
        if failures > 0 { print("ShoppingRoutingChecks: \(failures) failures across \(cases) synthetic inputs"); exit(1) }
        print("ShoppingRoutingChecks OK (\(cases) synthetic inputs plus persisted-state checks)")
    }
}
