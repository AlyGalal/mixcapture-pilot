import Foundation

/// Synthetic data for native iPhone-simulator UI tests only.
///
/// Compiled to a no-op outside Debug simulator builds, and even there it runs only when the
/// UI test passes `--ui-testing`. It uses the same public model APIs as the app, never schedules
/// notifications or touches EventKit, and only seeds when the local store is empty, so a real
/// phone store (a device build) is never touched and relaunches never duplicate fixtures.
enum SimulatorFixtures {
    /// Fixed IDs so the seeded capture/receipt are stable across relaunches.
    static let fixtureCaptureID = UUID(uuidString: "5EED0000-0000-4000-8000-000000000001")!
    static let fixtureReviewSourceID = UUID(uuidString: "5EED0000-0000-4000-8000-000000000002")!

    @MainActor
    static func installIfRequested() async {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        await seed()
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    @MainActor
    private static func seed() async {
        installFixtureCapture()

        let model = LocalItemsModel.shared
        guard model.storageError == nil,
              model.libraryItems.isEmpty, model.snapshot.expenses.isEmpty else { return }

        let cal = Calendar.current
        let now = Date()
        func future(days: Int, hour: Int) -> Date {
            let day = cal.date(byAdding: .day, value: days, to: now) ?? now.addingTimeInterval(Double(days) * 86_400)
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }

        do {
            try model.upsertLibrary(OrganizerItem(kind: .note, title: "أفكار تطبيق الملاحظات",
                                                  body: "ملاحظة تجريبية: نجرّب التنظيم المحلي للأوامر الصوتية بالعربي والإنجليزي."))
            try model.upsertLibrary(OrganizerItem(kind: .note, title: "اجتماع الأسبوع القادم",
                                                  body: "نراجع الخطة مع الفريق ونحدد الأولويات."))
            try model.upsertLibrary(OrganizerItem(kind: .task, title: "مراجعة ميزانية مشروع Home",
                                                  body: "راجع budget المشروع قبل نهاية الأسبوع.",
                                                  collection: "Home", dueDate: future(days: 2, hour: 10)))
            try model.upsertLibrary(OrganizerItem(kind: .task, title: "تجهيز تقرير Home",
                                                  body: "جهّز التقرير الشهري للمشروع.",
                                                  collection: "Home", dueDate: future(days: 4, hour: 12)))
            try model.upsertLibrary(OrganizerItem(kind: .shopping, title: "لبن زبادي",
                                                  body: "علبتين",
                                                  collection: "Groceries"))
            try model.upsertLibrary(OrganizerItem(kind: .shopping, title: "خبز",
                                                  body: "٣ أرغفة",
                                                  collection: "Groceries"))
            try model.upsertLibrary(OrganizerItem(kind: .recipe, title: "مكرونة بالطماطم",
                                                  body: "وصفة سريعة للعشاء.",
                                                  ingredients: ["٢٠٠ جرام مكرونة", "٣ حبات طماطم", "فص ثوم", "ملح وفلفل"],
                                                  steps: ["اسلق المكرونة في ماء مملح.",
                                                          "قلّب الثوم والطماطم في مقلاة حتى تنضج الصلصة.",
                                                          "اخلط المكرونة مع الصلصة وقدّمها ساخنة."]))
            try model.upsertLibrary(OrganizerItem(kind: .calendar, title: "اجتماع تصميم",
                                                  body: "مراجعة التصميم مع الفريق.",
                                                  dueDate: future(days: 3, hour: 15),
                                                  endDate: future(days: 3, hour: 16)))

            try model.addExpense(date: now, title: "بقالة", amountText: "350.50", currency: .EGP,
                                 category: .groceries, sourceCaptureID: nil, sourceTranscript: nil)
            try model.addExpense(date: now, title: "اشتراك برنامج", amountText: "12.99", currency: .USD,
                                 category: .bills, sourceCaptureID: nil, sourceTranscript: nil)
            // Saved as pending only; no notification is scheduled (no permission prompt).
            _ = try model.createReminder(title: "مكالمة المهندس", date: future(days: 1, hour: 18),
                                         sourceCaptureID: nil, sourceTranscript: nil)

            // An ambiguous reminder command (no AM/PM) lands in the review queue.
            if model.reviewItems.isEmpty, model.receipt(for: fixtureReviewSourceID) == nil {
                _ = try await model.organize(text: "فكرني الساعة خمسة", sourceID: fixtureReviewSourceID,
                                             recordedAt: now)
            }
        } catch {
            NSLog("SimulatorFixtures seeding stopped: \(error.localizedDescription)")
        }
    }

    /// A transcribed capture that is not eligible for organization, so nothing acts on it.
    @MainActor
    private static func installFixtureCapture() {
        let capture = CaptureModel.shared
        guard !capture.records.contains(where: { $0.id == fixtureCaptureID }) else { return }
        var record = CaptureRecord(id: fixtureCaptureID, recordedAt: Date().addingTimeInterval(-3_600),
                                   requestedLocale: PilotLocale.mixedArabicEnglish.rawValue, testCase: nil,
                                   device: "iPhone Simulator", osVersion: "iOS Simulator")
        record.finishRecording(durationSeconds: 4.7, interrupted: false)
        record.finishTranscription(segments: ["ضيف review الـbudget لمشروع Home وفكرني بيه بكرة"],
                                   resolvedLocale: "ar", engine: "fixture", processingSeconds: 0.1)
        record.organizationEligible = false
        capture.records.insert(record, at: 0)
    }
    #endif
}
