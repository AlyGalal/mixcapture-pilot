import SwiftUI
import UIKit

// MARK: - Labels

private extension ExpenseCategory {
    var label: String {
        switch self {
        case .food: return "طعام"
        case .groceries: return "بقالة"
        case .transport: return "مواصلات"
        case .bills: return "فواتير"
        case .shopping: return "تسوق"
        case .health: return "صحة"
        case .other: return "أخرى"
        }
    }
}

private func statusText(_ r: ReminderItem, now: Date = Date()) -> String {
    if r.status == .completed { return "مكتمل" }
    if r.scheduledDate <= now { return "الموعد مرّ" }
    switch r.status {
    case .scheduled: return "مجدول على الجهاز (التنبيه الفعلي يعتمد على إعدادات الجهاز)"
    case .pending: return "محفوظ — لم يُجدول بعد"
    case .needsPermission: return "محفوظ — غير مجدول: الإشعارات غير مسموحة"
    case .failed: return "محفوظ — غير مجدول: فشلت الجدولة"
    case .completed: return "مكتمل"
    }
}

private func openAppSettings(_ openURL: OpenURLAction) {
    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
}

// MARK: - Expenses

struct ExpensesScreen: View {
    private let model = LocalItemsModel.shared
    @State private var month = Date()
    @State private var showingEditor = false

    private var monthExpenses: [ExpenseItem] {
        model.snapshot.expenses
            .filter { Calendar.current.isDate($0.date, equalTo: month, toGranularity: .month) }
            .sorted { $0.date > $1.date }
    }

    private func shiftMonth(_ delta: Int) {
        month = Calendar.current.date(byAdding: .month, value: delta, to: month) ?? month
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.storageError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    ViewThatFits {
                        HStack {
                            Button("الشهر السابق", systemImage: "chevron.right") { shiftMonth(-1) }
                                .labelStyle(.iconOnly)
                            Spacer()
                            Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                            Spacer()
                            Button("الشهر التالي", systemImage: "chevron.left") { shiftMonth(1) }
                                .labelStyle(.iconOnly)
                        }
                        VStack {
                            Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                            HStack {
                                Button("الشهر السابق") { shiftMonth(-1) }
                                Button("الشهر التالي") { shiftMonth(1) }
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Section("ملخص الشهر (لكل عملة على حدة)") {
                    let totals = monthlySummary(model.snapshot.expenses, month: month)
                    if totals.isEmpty {
                        Text("لا توجد مصروفات في هذا الشهر")
                    }
                    ForEach(totals, id: \.currency) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("الإجمالي: \(formatAmount(t.totalMinorUnits, t.currency))").font(.headline)
                            ForEach(ExpenseCategory.allCases.filter { t.byCategory[$0] != nil }) { c in
                                Text("\(c.label): \(formatAmount(t.byCategory[c] ?? 0, t.currency))")
                                    .font(.subheadline)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section("المصروفات") {
                    ForEach(monthExpenses) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).lineLimit(2)
                            Text("\(e.date.formatted(date: .abbreviated, time: .omitted)) · \(e.category.label) · \(formatAmount(e.amountMinorUnits, e.currency))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("المصروفات")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: model.exportJSON()) { Label("تصدير JSON", systemImage: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("إضافة مصروف", systemImage: "plus") { showingEditor = true }
                        .disabled(model.storageError != nil)
                }
            }
            .sheet(isPresented: $showingEditor) { ExpenseEditor() }
        }
    }
}

struct ExpenseEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let model = LocalItemsModel.shared
    private let sourceID: UUID?
    private let sourceTranscript: String?

    @State private var title: String
    @State private var amount = ""
    @State private var currency = Currency.EGP
    @State private var category: ExpenseCategory?
    @State private var date: Date
    @State private var error: String?
    @State private var saving = false

    init(source: CaptureRecord? = nil) {
        sourceID = source?.id
        sourceTranscript = source?.transcript
        _title = State(initialValue: source?.transcript ?? "")
        _date = State(initialValue: source?.recordedAt ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("العنوان", text: $title, axis: .vertical)
                    TextField("المبلغ (مثال: 120.50)", text: $amount)
                        .keyboardType(.decimalPad)
                        .environment(\.layoutDirection, .leftToRight)
                    Picker("العملة", selection: $currency) {
                        ForEach(Currency.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("الفئة", selection: $category) {
                        Text("اختر الفئة").tag(ExpenseCategory?.none)
                        ForEach(ExpenseCategory.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    DatePicker("التاريخ", selection: $date, displayedComponents: .date)
                } footer: {
                    Text("راجع المبلغ والفئة بنفسك قبل الحفظ؛ لا يتم استخراجهما تلقائياً من التسجيل.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("مصروف جديد")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ", action: save).disabled(saving || category == nil)
                }
            }
        }
    }

    private func save() {
        guard !saving, let category else { return }
        saving = true
        do {
            try model.addExpense(date: date, title: title, amountText: amount, currency: currency,
                                 category: category, sourceCaptureID: sourceID, sourceTranscript: sourceTranscript)
            dismiss()
        } catch {
            saving = false
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Reminders

struct RemindersScreen: View {
    private let model = LocalItemsModel.shared
    @Environment(\.openURL) private var openURL
    @State private var showingEditor = false
    @State private var error: String?

    private var reminders: [ReminderItem] {
        model.snapshot.reminders.sorted { $0.scheduledDate < $1.scheduledDate }
    }

    var body: some View {
        NavigationStack {
            List {
                if let e = model.storageError ?? model.saveError {
                    Section { Text(e).foregroundStyle(.red) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                ForEach(reminders) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(r.title).lineLimit(3)
                        Text(r.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(statusText(r)).font(.subheadline)
                        if let e = r.scheduleError, r.status != .completed {
                            Text(e).font(.footnote).foregroundStyle(.red)
                        }
                        if r.status != .completed {
                            VStack(alignment: .leading) {
                                if r.status != .scheduled && r.scheduledDate > Date() {
                                    Button("إعادة المحاولة") { run { _ = try await model.schedule(id: r.id) } }
                                }
                                if r.status == .needsPermission {
                                    Button("فتح الإعدادات") { openAppSettings(openURL) }
                                }
                                Button("تم / إلغاء التذكير") { run { try await model.complete(id: r.id) } }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            .overlay {
                if reminders.isEmpty { Text("لا توجد تذكيرات") .foregroundStyle(.secondary) }
            }
            .navigationTitle("التذكيرات")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("إضافة تذكير", systemImage: "plus") { showingEditor = true }
                        .disabled(model.storageError != nil)
                }
            }
            .sheet(isPresented: $showingEditor) { ReminderEditor() }
            .task { await model.reconcile() }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action(); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

struct ReminderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private let model = LocalItemsModel.shared
    private let sourceID: UUID?
    private let sourceTranscript: String?

    @State private var title: String
    @State private var date = Date().addingTimeInterval(3600)
    @State private var busy = false
    @State private var error: String?
    @State private var saved: ReminderItem?

    init(source: CaptureRecord? = nil) {
        sourceID = source?.id
        sourceTranscript = source?.transcript
        _title = State(initialValue: source?.transcript ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("العنوان", text: $title, axis: .vertical)
                    DatePicker("الموعد", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text("الموعد المقترح مجرد قيمة افتراضية؛ راجعه وعدّله بنفسك. لا يتم استخراجه من التسجيل.")
                }
                .disabled(busy || saved != nil)
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let saved {
                    Section("الحالة") {
                        Text(statusText(saved))
                        if let e = saved.scheduleError { Text(e).foregroundStyle(.red) }
                        VStack(alignment: .leading) {
                            if saved.status == .needsPermission {
                                Button("فتح الإعدادات") { openAppSettings(openURL) }
                            }
                            if saved.scheduledDate > Date() {
                                Button("إعادة المحاولة") { retry(saved.id) }.disabled(busy)
                            }
                            Button("إغلاق") { dismiss() }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("تذكير جديد")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ وجدولة", action: save).disabled(busy || saved != nil)
                }
            }
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let item = try model.createReminder(title: title, date: date,
                                                    sourceCaptureID: sourceID, sourceTranscript: sourceTranscript)
                saved = item // retain this ID even when native scheduling or its acknowledgement fails
                finish(try await model.schedule(id: item.id))
            }
            catch { self.error = error.localizedDescription }
        }
    }

    private func retry(_ id: UUID) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { finish(try await model.schedule(id: id)) } catch { self.error = error.localizedDescription }
        }
    }

    private func finish(_ item: ReminderItem) {
        if item.status == .scheduled { dismiss() } else { saved = item }
    }
}
