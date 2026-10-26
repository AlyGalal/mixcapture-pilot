import SwiftUI
import UIKit

// MARK: - Labels

extension ExpenseCategory {
    var label: String {
        switch self {
        case .food: return "Food"
        case .groceries: return "Groceries"
        case .transport: return "Transport"
        case .bills: return "Bills"
        case .shopping: return "Shopping"
        case .health: return "Health"
        case .other: return "Other"
        }
    }
}

func reminderStatusText(_ r: ReminderItem, now: Date = Date()) -> String {
    if r.status == .completed { return "Completed" }
    if r.scheduledDate <= now { return "Time has passed" }
    switch r.status {
    case .scheduled: return "Scheduled on this device; alerts depend on device settings"
    case .pending: return "Saved, not scheduled yet"
    case .needsPermission: return "Saved, not scheduled: notifications are not allowed"
    case .failed: return "Saved, not scheduled: scheduling failed"
    case .completed: return "Completed"
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
    @State private var editing: ExpenseItem?
    @State private var pendingDelete: ExpenseItem?
    @State private var error: String?

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
                if model.storageError != nil || model.saveError != nil {
                    Section { StorageBanner().listRowInsets(EdgeInsets()) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    ViewThatFits {
                        HStack {
                            Button("Previous month", systemImage: "chevron.left") { shiftMonth(-1) }
                                .labelStyle(.iconOnly)
                            Spacer()
                            Text(month.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US")))).font(.headline)
                            Spacer()
                            Button("Next month", systemImage: "chevron.right") { shiftMonth(1) }
                                .labelStyle(.iconOnly)
                        }
                        VStack {
                            Text(month.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US")))).font(.headline)
                            HStack {
                                Button("Previous month") { shiftMonth(-1) }
                                Button("Next month") { shiftMonth(1) }
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Section("Monthly summary by currency") {
                    let totals = monthlySummary(model.snapshot.expenses, month: month)
                    if totals.isEmpty {
                        Text("No expenses this month").foregroundStyle(.secondary)
                    }
                    ForEach(totals, id: \.currency) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total: \(formatAmount(t.totalMinorUnits, t.currency))")
                                .font(.headline)
                                .foregroundStyle(Theme.teal)
                            ForEach(ExpenseCategory.allCases.filter { t.byCategory[$0] != nil }) { c in
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(c.label)
                                        Spacer()
                                        Text(formatAmount(t.byCategory[c] ?? 0, t.currency))
                                    }
                                    .font(.subheadline)
                                    ProgressView(value: NSDecimalNumber(decimal: t.byCategory[c] ?? 0).doubleValue /
                                                 max(1, NSDecimalNumber(decimal: t.totalMinorUnits).doubleValue))
                                        .tint(Theme.teal)
                                        .accessibilityHidden(true)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section("Expenses") {
                    ForEach(monthExpenses) { e in
                        Button { editing = e } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).lineLimit(2).foregroundStyle(Theme.ink)
                                Text("\(e.date.formatted(.dateTime.month(.abbreviated).day().year().locale(Locale(identifier: "en_US")))) · \(e.category.label) · \(formatAmount(e.amountMinorUnits, e.currency))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Tap to edit")
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDelete = e }
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = e }
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = e }
                        }
                    }
                    if monthExpenses.isEmpty {
                        Text("Tap + to add an expense or record it with your voice.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .navigationTitle("Expenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add expense", systemImage: "plus") { showingEditor = true }
                        .disabled(model.storageError != nil)
                        .accessibilityIdentifier("expenses.add")
                }
            }
            .sheet(isPresented: $showingEditor) { ExpenseEditor() }
            .sheet(item: $editing) { ExpenseEditor(existing: $0) }
            .confirmationDialog("Delete expense?", isPresented: Binding(get: { pendingDelete != nil },
                                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { e in
                Button("Delete", role: .destructive) {
                    do { try model.deleteExpense(id: e.id); error = nil } catch { self.error = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct ExpenseEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let model = LocalItemsModel.shared
    private let sourceID: UUID?
    private let sourceTranscript: String?
    private let existing: ExpenseItem?

    @State private var title: String
    @State private var amount: String
    @State private var currency: Currency
    @State private var category: ExpenseCategory?
    @State private var date: Date
    @State private var error: String?
    @State private var saving = false

    init(source: CaptureRecord? = nil, existing: ExpenseItem? = nil) {
        self.existing = existing
        sourceID = existing?.sourceCaptureID ?? source?.id
        sourceTranscript = existing?.sourceTranscript ?? source?.transcript
        _title = State(initialValue: existing?.title ?? source?.transcript ?? "")
        _amount = State(initialValue: existing.map { NSDecimalNumber(decimal: Decimal($0.amountMinorUnits) / 100).stringValue } ?? "")
        _currency = State(initialValue: existing?.currency ?? .EGP)
        _category = State(initialValue: existing?.category)
        _date = State(initialValue: existing?.date ?? source?.recordedAt ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                    TextField("Amount (e.g. 120.50)", text: $amount)
                        .keyboardType(.decimalPad)
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityIdentifier("expense.amount")
                    Picker("Currency", selection: $currency) {
                        ForEach(Currency.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Category", selection: $category) {
                        Text("Choose a category").tag(ExpenseCategory?.none)
                        ForEach(ExpenseCategory.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                } footer: {
                    Text("Manual entry: review the amount and category before saving.")
                }
                if let sourceTranscript, !sourceTranscript.isEmpty {
                    Section("Original text") {
                        Text(sourceTranscript).textSelection(.enabled)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "New expense" : "Edit expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(saving || category == nil || model.storageError != nil)
                        .accessibilityIdentifier("expense.save")
                }
            }
        }
    }

    private func save() {
        guard !saving, let category else { return }
        saving = true
        do {
            if var item = existing {
                guard let minor = parseAmount(amount) else { throw LocalItemsError.invalidAmount }
                item.title = try validatedTitle(title)
                item.amountMinorUnits = minor
                item.currency = currency
                item.category = category
                item.date = date
                try model.upsertExpense(item)
            } else {
                try model.addExpense(date: date, title: title, amountText: amount, currency: currency,
                                     category: category, sourceCaptureID: sourceID, sourceTranscript: sourceTranscript)
            }
            dismiss()
        } catch {
            saving = false
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Reminders

/// Standalone tab screen, or `embedded: true` when pushed inside an existing NavigationStack.
struct RemindersScreen: View {
    var embedded = false

    var body: some View {
        if embedded {
            RemindersList()
        } else {
            NavigationStack { RemindersList() }
        }
    }
}

private struct RemindersList: View {
    private let model = LocalItemsModel.shared
    @Environment(\.openURL) private var openURL
    @State private var showingEditor = false
    @State private var error: String?

    private var active: [ReminderItem] {
        model.snapshot.reminders.filter { $0.status != .completed }.sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var completed: [ReminderItem] {
        model.snapshot.reminders.filter { $0.status == .completed }.sorted { $0.scheduledDate > $1.scheduledDate }
    }

    var body: some View {
        List {
            if model.storageError != nil || model.saveError != nil {
                Section { StorageBanner().listRowInsets(EdgeInsets()) }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                ForEach(active) { reminderRow($0) }
                if active.isEmpty {
                    Text("No active reminders").foregroundStyle(.secondary)
                }
            } footer: {
                Text("These are local notifications on this device, not a sync with Apple Reminders.")
            }
            if !completed.isEmpty {
                Section("Completed") {
                    ForEach(completed) { reminderRow($0) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add reminder", systemImage: "plus") { showingEditor = true }
                    .disabled(model.storageError != nil)
                    .accessibilityIdentifier("reminders.add")
            }
        }
        .sheet(isPresented: $showingEditor) { ReminderEditor() }
        .task { await model.reconcile() }
    }

    private func reminderRow(_ r: ReminderItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.title).lineLimit(3).strikethrough(r.status == .completed)
            Text(r.scheduledDate.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().locale(Locale(identifier: "en_US"))))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(reminderStatusText(r))
                .font(.subheadline)
                .foregroundStyle(r.status == .scheduled || r.status == .completed ? Theme.teal : Theme.warn)
            if let e = r.scheduleError, r.status != .completed {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
            if r.status != .completed {
                VStack(alignment: .leading) {
                    if r.status != .scheduled && r.scheduledDate > Date() {
                        Button("Retry") { run { _ = try await model.schedule(id: r.id) } }
                    }
                    if r.status == .needsPermission {
                        Button("Open Settings") { openAppSettings(openURL) }
                    }
                    Button("Complete or cancel reminder") { run { try await model.complete(id: r.id) } }
                }
                .buttonStyle(.borderless)
            }
        }
        .accessibilityElement(children: .contain)
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
                    TextField("Title", text: $title, axis: .vertical)
                    DatePicker("Date and time", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text("Manual entry: the suggested time is a default. Review and change it before saving. This reminder uses a local notification.")
                }
                .disabled(busy || saved != nil)
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if let saved {
                    Section("Status") {
                        Text(reminderStatusText(saved))
                        if let e = saved.scheduleError { Text(e).foregroundStyle(.red) }
                        VStack(alignment: .leading) {
                            if saved.status == .needsPermission {
                                Button("Open Settings") { openAppSettings(openURL) }
                            }
                            if saved.scheduledDate > Date() {
                                Button("Retry") { retry(saved.id) }.disabled(busy)
                            }
                            Button("Close") { dismiss() }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("New reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save and schedule", action: save).disabled(busy || saved != nil)
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
