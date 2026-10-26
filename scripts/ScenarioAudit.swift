import Foundation

// Diagnostic corpus audit: gaps are reported, not redefined as successful understanding.
// Pure parser calls only; no recordings, persistence, notifications or calendar writes.
@main
struct ScenarioAudit {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Scenario audit error: \(message)\n".utf8))
        exit(1)
    }

    static func normalized(_ value: String) -> String {
        value.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fail("Expected corpus.json and results.json paths") }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as? [String: Any],
              let rows = root["cases"] as? [[String: Any]], rows.count == 100,
              let anchor = root["anchor"] as? String,
              let now = ISO8601DateFormatter().date(from: anchor) else { fail("Invalid corpus or anchor; exactly 100 cases required") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Cairo")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let iso = ISO8601DateFormatter()
        iso.timeZone = calendar.timeZone
        var ids = Set<String>(), utterances = Set<String>()
        var results: [[String: Any]] = []
        var counts: [String: Int] = ["auto_match": 0, "safe_review": 0, "review_gap": 0,
                                    "interpretation_gap": 0, "capability_gap": 0, "review_gate_gap": 0]
        let kinds = Set(OrganizationKind.allCases.map(\.rawValue))
        let knownFields: Set<String> = ["kind", "title", "collection", "amount_minor", "currency", "category",
            "after_minutes", "due_local", "duration_minutes", "day", "ingredients", "steps"]

        func actual(_ draft: OrganizationDraft) -> [String: Any] {
            var data: [String: Any] = ["kind": draft.kind.rawValue, "title": draft.title,
                                      "collection": draft.collection, "requires_review": draft.requiresReview]
            if let reason = draft.reason { data["reason"] = reason }
            if draft.kind == .expense {
                data["amount_text"] = draft.amountText
                if let amount = parseAmount(draft.amountText) { data["amount_minor"] = amount }
                data["currency"] = draft.currency.rawValue
                data["category"] = draft.category.rawValue
            }
            if let date = draft.dueDate { data["due_local"] = iso.string(from: date) }
            if let end = draft.endDate { data["end_local"] = iso.string(from: end) }
            if !draft.ingredients.isEmpty { data["ingredients"] = draft.ingredients }
            if !draft.steps.isEmpty { data["steps"] = draft.steps }
            return data
        }

        func differences(_ wanted: [String: Any], _ draft: OrganizationDraft) -> [String] {
            var issues: [String] = []
            if wanted["kind"] as? String != draft.kind.rawValue { issues.append("Action type differs") }
            if wanted["kind"] as? String != "note", let title = wanted["title"] as? String {
                let expected = normalized(title), got = normalized(draft.title)
                if got != expected && !(" " + got + " ").contains(" " + expected + " ") {
                    issues.append("Expected title content is missing")
                }
            }
            if let collection = wanted["collection"] as? String,
               normalized(collection) != normalized(draft.collection) { issues.append("Collection differs") }
            if let amount = wanted["amount_minor"] as? NSNumber,
               parseAmount(draft.amountText) != amount.int64Value { issues.append("Amount differs") }
            if let currency = wanted["currency"] as? String,
               currency.lowercased() != draft.currency.rawValue.lowercased() { issues.append("Currency differs") }
            if let category = wanted["category"] as? String,
               category != draft.category.rawValue { issues.append("Expense category differs") }
            var expectedDate: Date?
            if let minutes = wanted["after_minutes"] as? NSNumber {
                expectedDate = now.addingTimeInterval(minutes.doubleValue * 60)
            }
            if let due = wanted["due_local"] as? String {
                guard let date = ISO8601DateFormatter().date(from: due) else { fail("Invalid expected due_local: \(due)") }
                expectedDate = date
            }
            if let date = expectedDate,
               draft.dueDate.map({ abs($0.timeIntervalSince(date)) < 1 }) != true { issues.append("Date or time differs") }
            if let duration = wanted["duration_minutes"] as? NSNumber {
                if let start = draft.dueDate, let end = draft.endDate {
                    if abs(end.timeIntervalSince(start) - duration.doubleValue * 60) >= 1 { issues.append("Duration differs") }
                } else { issues.append("Event duration is missing") }
            }
            if wanted["day"] != nil { issues.append("Date-only planning is not represented by the current model") }
            for key in wanted.keys.sorted() where !knownFields.contains(key) {
                issues.append("Expected property is not represented: \(key)")
            }
            for (key, got) in [("ingredients", draft.ingredients), ("steps", draft.steps)] {
                if let expected = wanted[key] as? [String], expected.map(normalized) != got.map(normalized) {
                    issues.append("\(key.capitalized) differ")
                }
            }
            return issues
        }

        for row in rows {
            guard let id = row["id"] as? String, ids.insert(id).inserted,
                  let text = row["utterance"] as? String, !text.isEmpty,
                  utterances.insert(normalized(text)).inserted,
                  let language = row["language"] as? String, ["ar", "en", "mixed"].contains(language),
                  let expected = row["expected"] as? [String: Any],
                  let mode = expected["mode"] as? String, ["auto", "clarify"].contains(mode),
                  let actions = expected["actions"] as? [[String: Any]],
                  mode == "clarify" || !actions.isEmpty else { fail("Invalid or duplicate scenario") }
            let pendingActions = expected["pending_actions"] as? [[String: Any]] ?? []
            if expected["pending_actions"] != nil && !(expected["pending_actions"] is [[String: Any]]) {
                fail("Invalid pending_actions in \(id)")
            }
            if mode == "clarify" {
                guard actions.isEmpty,
                      expected["pending_actions"] is [[String: Any]],
                      let executed = expected["executed_actions"] as? [[String: Any]], executed.isEmpty else {
                    fail("Clarify case \(id) must have empty actions/executed_actions and explicit pending_actions")
                }
            }
            let desiredIntents = mode == "clarify" ? pendingActions : actions
            guard (actions + pendingActions).allSatisfy({ $0["kind"] is String }) else {
                fail("Missing action kind in \(id)")
            }
            let drafts = OrganizerParser.parse(text, now: now, calendar: calendar)
            guard !drafts.isEmpty, drafts.allSatisfy({ $0.body == text }) else {
                fail("Production parser discarded or rewrote source \(id)")
            }
            var issues: [String] = []
            var capabilityGaps: [String] = []
            var warnings: [String] = []
            for action in desiredIntents {
                if let kind = action["kind"] as? String, !kinds.contains(kind) { capabilityGaps.append(kind) }
                if action["day"] != nil { capabilityGaps.append("date_only_planning") }
                capabilityGaps += action.keys.filter { !knownFields.contains($0) }.sorted()
            }
            if row["state"] != nil {
                guard row["state"] is [String: Any] else { fail("Invalid desired fixture state in \(id)") }
                capabilityGaps.append("stateful_context")
                warnings.append("Desired fixture state was not consumed by the stateless parser; existing-item lookup, UUID preservation and mutations were not tested")
            }
            let status: String
            if mode == "clarify" {
                if drafts.allSatisfy(\.requiresReview) {
                    status = capabilityGaps.isEmpty ? "safe_review" : "capability_gap"
                    if !capabilityGaps.isEmpty {
                        issues.append("The review gate stopped automatic candidates, but the desired pending capability is not implemented")
                    }
                } else {
                    status = "review_gate_gap"
                    issues.append("Expected clarification, but at least one parser draft is eligible for automatic application; this audit executed nothing")
                }
            } else {
                if drafts.count != actions.count { issues.append("Expected \(actions.count) actions, got \(drafts.count)") }
                for (wanted, draft) in zip(actions, drafts) { issues += differences(wanted, draft) }
                if drafts.contains(where: \.requiresReview) { issues.append("A clear intended command was held for review") }
                if !capabilityGaps.isEmpty {
                    status = "capability_gap"
                } else if issues.isEmpty {
                    status = "auto_match"
                } else {
                    status = drafts.allSatisfy(\.requiresReview) ? "review_gap" : "interpretation_gap"
                }
            }
            counts[status, default: 0] += 1
            var result = row
            result["actual"] = drafts.map(actual)
            result["automatic_candidates"] = drafts.filter { !$0.requiresReview }.map(actual)
            // This diagnostic never applies drafts. A candidate is not an executed action.
            result["executed_actions"] = [[String: Any]]()
            result["state_consumed"] = false
            result["warnings"] = warnings
            if mode == "clarify" { result["review_gate_passed"] = drafts.allSatisfy(\.requiresReview) }
            result["status"] = status
            result["differences"] = issues
            result["capability_gaps"] = Array(Set(capabilityGaps)).sorted()
            // Note titles are human reference summaries; capture is judged by kind, destination
            // and preservation of the full original body, not exact paraphrase generation.
            result["note_title_reference"] = desiredIntents.contains { $0["kind"] as? String == "note" }
            results.append(result)
            print("\(id) \(status)")
        }
        guard ids == Set((1...100).map { String(format: "D%03d", $0) }) else { fail("Expected IDs D001 through D100") }
        let report: [String: Any] = ["schema_version": 2, "anchor": anchor, "timezone": "Africa/Cairo",
            "evaluation": "Production stateless text parser only; drafts were not applied, fixture state was not consumed, and audio recognition, clarification dialogs and native side effects were not tested",
            "summary": counts, "cases": results]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: output, options: .atomic)
        print("AUDIT COMPLETE: \(results.count) scenarios; auto_match=\(counts["auto_match"]!), safe_review=\(counts["safe_review"]!)")
        print("Gaps are diagnostics, not passing feature tests. Report: \(output.path)")
    }
}
