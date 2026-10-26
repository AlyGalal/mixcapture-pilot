import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CoreTransferable

private struct OrganizerBackup: Transferable {
    let contents: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { (backup: OrganizerBackup) in Data(backup.contents.utf8) }
            .suggestedFileName("MixCapture-backup.json")
    }
}

// Personal organizer UI: tabs, record dock, home, library, review queue and settings.
// Uses only the shared local models (CaptureModel, LocalItemsModel, CalendarBridge).

// MARK: - Theme

enum Theme {
    static let teal = Color(light: 0x0F766E, dark: 0x5EEAD4)
    static let onTeal = Color(light: 0xFFFFFF, dark: 0x042F2E)
    static let mint = Color(light: 0xDDF3EE, dark: 0x16322F)
    static let ink = Color(light: 0x16302F, dark: 0xE9F2F0)
    static let surface = Color(light: 0xFAF6EF, dark: 0x151413)
    static let card = Color(light: 0xFFFFFF, dark: 0x22211F)
    static let hairline = Color(light: 0xE7E0D3, dark: 0x34322E)
    static let warn = Color(light: 0xB45309, dark: 0xFBBF24)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self = Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func organizerCard() -> some View { modifier(CardStyle()) }
}

extension OrganizerKind {
    var uiSymbol: String {
        switch self {
        case .note: return "note.text"
        case .task: return "checklist"
        case .shopping: return "cart"
        case .recipe: return "fork.knife"
        case .calendar: return "calendar"
        }
    }
}

extension OrganizationKind {
    var uiSymbol: String {
        switch self {
        case .note: return "note.text"
        case .task: return "checklist"
        case .shopping: return "cart"
        case .recipe: return "fork.knife"
        case .calendar: return "calendar"
        case .reminder: return "bell"
        case .expense: return "creditcard"
        }
    }
}

private func shortDateTime(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().locale(Locale(identifier: "en_US")))
}

private func captureStatusLabel(_ status: CaptureStatus) -> String {
    switch status {
    case .recording: return "Recording"
    case .interrupted: return "Interrupted"
    case .pendingTranscription: return "Waiting to transcribe"
    case .transcribing: return "Transcribing"
    case .transcribed: return "Transcribed"
    case .failed: return "Failed"
    }
}

/// One entry per line; if the text was not edited the original array is kept untouched.
private func parseLines(_ text: String, original: [String]) -> [String] {
    if text == original.joined(separator: "\n") { return original }
    return text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

// MARK: - Shared small views

struct StorageBanner: View {
    private let items = LocalItemsModel.shared

    var body: some View {
        if let error = items.storageError {
            banner(title: "Saving is paused", message: error, color: .red, symbol: "exclamationmark.octagon.fill")
        } else if let error = items.saveError {
            banner(title: "Could not save the last change", message: error, color: Theme.warn, symbol: "exclamationmark.triangle.fill")
        }
    }

    private func banner(title: String, message: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(color)
                Text(message).font(.footnote).textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("storage.error")
    }
}

private struct SectionTitle: View {
    let title: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).foregroundStyle(Theme.teal) }
            Text(title).font(.headline).foregroundStyle(Theme.ink)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct OptionalDateRow: View {
    let title: String
    @Binding var date: Date?
    var fallback: () -> Date = { Date() }

    var body: some View {
        Toggle(title, isOn: Binding(get: { date != nil }, set: { date = $0 ? (date ?? fallback()) : nil }))
        if let current = date {
            DatePicker(title, selection: Binding(get: { current }, set: { date = $0 }),
                       displayedComponents: [.date, .hourAndMinute])
        }
    }
}

// MARK: - Shell

enum OrganizerTab: Hashable {
    case home, library, expenses, settings
}

struct OrganizerShell: View {
    @Bindable var model: CaptureModel
    @State private var tab: OrganizerTab = .home
    @State private var showRecording = false
    @State private var showCommand = false

    private var dock: RecordDock {
        RecordDock(model: model, onRecord: openRecording, onType: { showCommand = true })
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeScreen(model: model, dock: dock, openCommand: { showCommand = true })
                .tabItem { Label("Today", systemImage: "sun.max").accessibilityIdentifier("tab.home") }
                .tag(OrganizerTab.home)
            LibraryScreen(dock: dock)
                .tabItem { Label("Library", systemImage: "books.vertical").accessibilityIdentifier("tab.library") }
                .tag(OrganizerTab.library)
            ExpensesScreen()
                .safeAreaInset(edge: .bottom, spacing: 0) { dock }
                .tabItem { Label("Expenses", systemImage: "creditcard").accessibilityIdentifier("tab.expenses") }
                .tag(OrganizerTab.expenses)
            SettingsScreen(model: model, dock: dock)
                .tabItem { Label("Settings", systemImage: "gearshape").accessibilityIdentifier("tab.settings") }
                .tag(OrganizerTab.settings)
        }
        .tint(Theme.teal)
        .onChange(of: model.isWaitingToStart, initial: true) { _, waiting in
            if waiting { revealRecording() }
        }
        .onChange(of: model.isRecording, initial: true) { _, recording in
            if recording { revealRecording() }
        }
        .sheet(isPresented: $showRecording) { RecordingSheet(model: model) }
        .sheet(isPresented: $showCommand) { CommandSheet() }
    }

    /// Dock tap: opens the sheet first, then requests a start only if none is running or queued.
    private func openRecording() {
        showCommand = false
        showRecording = true
        if !model.isRecording && !model.isWaitingToStart { model.requestStart() }
    }

    /// External start (Back Tap, URL, Shortcut): go home and show the sheet, unless the dock already did.
    private func revealRecording() {
        guard !showRecording else { return }
        showCommand = false
        tab = .home
        showRecording = true
    }
}

// MARK: - Record dock

struct RecordDock: View {
    let model: CaptureModel
    let onRecord: () -> Void
    let onType: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onType) {
                Image(systemName: "keyboard")
                    .font(.title3)
                    .foregroundStyle(Theme.teal)
                    .frame(width: 48, height: 48)
                    .background(Theme.mint, in: Circle())
            }
            .accessibilityLabel("Type a command")
            .accessibilityIdentifier("action.type")

            statusView
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRecord) {
                Image(systemName: model.isRecording ? "waveform" : "mic.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.onTeal)
                    .frame(width: 60, height: 60)
                    .background(model.isRecording ? Color.red : Theme.teal, in: Circle())
            }
            .accessibilityLabel(model.isRecording ? "Recording in progress. Open recording controls." : "Record")
            .accessibilityIdentifier("action.record")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.status {
        case .idle:
            line("Tap to record or type a command", color: .secondary)
        case .waitingToStart:
            line("Waiting to start recording…", color: .secondary)
        case .recording:
            if let active = model.activeRecord {
                VStack(alignment: .leading, spacing: 2) {
                    Text(active.recordedAt, style: .timer)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Recording").font(.caption).foregroundStyle(.red)
                }
                .accessibilityElement(children: .combine)
            }
        case .processing:
            line("Transcribing on device…", color: .secondary)
        case .saved(let message):
            line(message, color: .secondary)
        case .failed(let message):
            line(message, color: .red)
        }
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text).font(.footnote).foregroundStyle(color).lineLimit(2)
    }
}

// MARK: - Recording sheet

struct RecordingSheet: View {
    @Bindable var model: CaptureModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    stateView
                    if !model.isRecording, !model.isWaitingToStart, let latest = model.records.first {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(title: "Latest recording", symbol: "waveform")
                            RecordingCard(model: model, recordID: latest.id)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.surface)
            .navigationTitle("Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .interactiveDismissDisabled(model.isRecording)
        .presentationDetents([.large])
        .onChange(of: model.isRecording, initial: true) { _, recording in pulse = recording }
    }

    @ViewBuilder
    private var stateView: some View {
        switch model.status {
        case .idle:
            VStack(spacing: 12) {
                Text("Ready. Tap to start a recording.").foregroundStyle(.secondary)
                startButton
            }
        case .waitingToStart:
            VStack(spacing: 12) {
                ProgressView()
                Text("Waiting for the app and microphone permission. Recording has not started.")
                    .multilineTextAlignment(.center)
                Button("Cancel request") { model.cancelPendingStart() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("recording.cancel")
            }
            .organizerCard()
        case .recording:
            recordingView
        case .processing:
            VStack(spacing: 12) {
                ProgressView()
                Text("Transcribing on this device…").font(.headline)
                Text("Longer recordings may take more time. Transcription pauses when you leave the app and resumes when you return.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .organizerCard()
        case .saved(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                startButton
            }
            .organizerCard()
        case .failed(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                startButton
            }
            .organizerCard()
        }
    }

    private var recordingView: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Color.red.opacity(0.35), lineWidth: 3)
                    .frame(width: 120, height: 120)
                    .scaleEffect(pulse && !reduceMotion ? 1.25 : 1)
                    .opacity(pulse && !reduceMotion ? 0.2 : 0.7)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                Circle().fill(Color.red).frame(width: 72, height: 72)
                Image(systemName: "mic.fill").font(.title).foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            if let active = model.activeRecord {
                Text(active.recordedAt, style: .timer)
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .accessibilityLabel("Recording duration")
            }
            Text("Recording. Tap Stop when you are finished.").font(.subheadline).foregroundStyle(.secondary)
            Text("On-device transcription supports recordings up to 30 minutes.")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                model.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityIdentifier("recording.stop")
        }
        .padding(.vertical, 8)
    }

    private var startButton: some View {
        Button {
            model.requestStart()
        } label: {
            Label("Record", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("recording.start")
    }
}

// MARK: - Recording card / detail

struct RecordingCard: View {
    @Bindable var model: CaptureModel
    let recordID: UUID
    private let items = LocalItemsModel.shared
    @State private var organizing = false
    @State private var organizeError: String?

    var body: some View {
        if let record = model.records.first(where: { $0.id == recordID }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(shortDateTime(record.recordedAt)).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(captureStatusLabel(record.status))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(record.status == .failed ? Color.red : Theme.teal)
                }
                if let transcript = record.transcript, !transcript.isEmpty {
                    Text(transcript)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(record.status == .failed ? "No transcript." : "No transcript yet.")
                        .foregroundStyle(.secondary)
                }
                if let error = record.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
                Text(durationText(record)).font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button {
                        model.togglePlayback(record)
                    } label: {
                        Label(model.playingID == record.id ? "Stop" : "Play audio",
                              systemImage: model.playingID == record.id ? "stop.fill" : "play.fill")
                    }
                    .disabled(model.isRecording)
                    .accessibilityIdentifier("recording.play")

                    Button {
                        model.retryTranscription(record.id)
                    } label: {
                        Label("Transcribe again", systemImage: "arrow.clockwise")
                    }
                    .disabled(!record.canRetry)
                    .accessibilityIdentifier("recording.retry")
                }
                .buttonStyle(.bordered)
                .font(.callout)

                HStack {
                    if let transcript = record.transcript {
                        ShareLink(item: transcript) { Label("Share text", systemImage: "square.and.arrow.up") }
                    }
                    if let audio = model.audioURL(for: record) {
                        ShareLink(item: audio) { Label("Share audio", systemImage: "waveform") }
                    }
                }
                .font(.footnote)

                if let receipt = items.receipt(for: record.id) {
                    ReceiptCard(receipt: receipt)
                } else if let transcript = record.transcript, !transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("This text has not been organized yet.").font(.footnote).foregroundStyle(.secondary)
                        Button {
                            organize(record, text: transcript)
                        } label: {
                            Label("Organize this text", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.bordered)
                        .disabled(organizing || items.storageError != nil)
                        if let organizeError {
                            Text(organizeError).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
            }
            .organizerCard()
        } else {
            Text("Recording not found.").foregroundStyle(.secondary).organizerCard()
        }
    }

    private func durationText(_ record: CaptureRecord) -> String {
        "Duration: \(record.durationSeconds.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US")))) s"
    }

    private func organize(_ record: CaptureRecord, text: String) {
        organizing = true
        organizeError = nil
        Task {
            defer { organizing = false }
            do {
                _ = try await items.organize(text: text, sourceID: record.id, recordedAt: record.recordedAt)
                await CalendarBridge.shared.syncPending()
            } catch {
                organizeError = error.localizedDescription
            }
        }
    }
}

struct RecordingDetailScreen: View {
    @Bindable var model: CaptureModel
    let recordID: UUID

    var body: some View {
        ScrollView {
            RecordingCard(model: model, recordID: recordID).padding(16)
        }
        .background(Theme.surface)
        .navigationTitle("Recording")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RecordingsListScreen: View {
    @Bindable var model: CaptureModel

    var body: some View {
        List {
            ForEach(model.records) { record in
                NavigationLink {
                    RecordingDetailScreen(model: model, recordID: record.id)
                } label: {
                    RecordingRowLabel(record: record)
                }
            }
        }
        .overlay {
            if model.records.isEmpty {
                ContentUnavailableView("No recordings", systemImage: "waveform",
                                       description: Text("Tap the microphone to record your first note."))
            }
        }
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RecordingRowLabel: View {
    let record: CaptureRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.transcript ?? captureStatusLabel(record.status))
                .lineLimit(2)
                .foregroundStyle(record.transcript == nil ? .secondary : Theme.ink)
            HStack {
                Text(shortDateTime(record.recordedAt))
                Text("·")
                Text(captureStatusLabel(record.status))
            }
            .font(.caption)
            .foregroundStyle(record.status == .failed ? Color.red : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Receipt card

struct ReceiptCard: View {
    private let initialReceipt: OrganizationReceipt
    private var receipt: OrganizationReceipt {
        LocalItemsModel.shared.receipt(for: initialReceipt.id) ?? initialReceipt
    }
    @State private var confirming = false
    @State private var error: String?

    init(receipt: OrganizationReceipt) { initialReceipt = receipt }

    private var statusLabel: String {
        switch receipt.status {
        case .applied: return "Organized"
        case .review: return "Needs review"
        case .undone: return "Undone"
        }
    }

    private var symbol: String {
        switch receipt.status {
        case .applied: return "checkmark.circle.fill"
        case .review: return "exclamationmark.circle.fill"
        case .undone: return "arrow.uturn.backward.circle"
        }
    }

    private var tint: Color {
        switch receipt.status {
        case .applied: return Theme.teal
        case .review: return Theme.warn
        case .undone: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(statusLabel, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Spacer()
                Text(shortDateTime(receipt.createdAt)).font(.caption).foregroundStyle(.secondary)
            }
            Text(receipt.summary).font(.callout).textSelection(.enabled)
            if let original = receipt.originalText {
                DisclosureGroup("Original text") { Text(original).textSelection(.enabled) }
                    .font(.footnote)
            }
            if receipt.status != .undone {
                Button(role: .destructive) {
                    confirming = true
                } label: {
                    Label("Undo organization", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .font(.callout)
                .accessibilityIdentifier("receipt.undo")
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .organizerCard()
        .confirmationDialog("Undo this organization?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Undo", role: .destructive) {
                do {
                    try CalendarBridge.shared.undoSource(receipt.id)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes items created from this source, including calendar events created by the app. The recording and original text stay unchanged.")
        }
    }
}

// MARK: - Command sheet (typed input)

private struct CommandExamples: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.examples, id: \.self) { example in
                Label(example, systemImage: "quote.opening")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    static let examples = [
        "paid 120.50 EGP for Uber",
        "add a task to review budget for project Home",
        "remind me tomorrow at 10 AM to review budget",
        "add milk and eggs to shopping list Groceries",
        "recipe Lentil soup: ingredients lentils and onion. steps boil the lentils then blend",
        "فكرني بعد 10 دقايق أراجع الـbudget",
    ]
}

struct CommandSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let items = LocalItemsModel.shared
    @State private var text = ""
    @State private var commandID = UUID()
    @State private var busy = false
    @State private var error: String?
    @State private var receipt: OrganizationReceipt?
    @FocusState private var editingCommand: Bool

    private var canSubmit: Bool {
        !busy && items.storageError == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    StorageBanner()
                    TextField("Type your command…", text: $text, axis: .vertical)
                        .focused($editingCommand)
                        .disabled(busy)
                        .lineLimit(3...8)
                        .padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline))
                        .accessibilityIdentifier("input.command")
                    Button(action: submit) {
                        HStack {
                            if busy { ProgressView() }
                            Text(busy ? "Organizing…" : "Organize command").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("action.saveCommand")

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let receipt { ReceiptCard(receipt: receipt) }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "Examples", symbol: "lightbulb")
                        CommandExamples()
                        Text("Organization runs on device using defined rules. Unclear commands go to review instead of being carried out.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
                .padding(16)
            }
            .background(Theme.surface)
            .navigationTitle("Typed command")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }

    private func submit() {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !busy else { return }
        editingCommand = false
        busy = true
        error = nil
        receipt = nil
        let id = commandID
        Task {
            defer { busy = false }
            do {
                let result = try await items.organize(text: command, sourceID: id)
                await CalendarBridge.shared.syncPending()
                receipt = result
                text = ""
                commandID = UUID()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Home

private struct UpcomingEntry: Identifiable {
    let id: UUID
    let title: String
    let date: Date
    let symbol: String
    let note: String
    let isWarning: Bool
    let libraryID: UUID?
}

struct HomeScreen: View {
    @Bindable var model: CaptureModel
    let dock: RecordDock
    let openCommand: () -> Void
    private let items = LocalItemsModel.shared

    private var upcoming: [UpcomingEntry] {
        let now = Date()
        var entries: [UpcomingEntry] = []
        for r in items.snapshot.reminders where r.status != .completed && r.scheduledDate > now {
            let scheduled = r.status == .scheduled
            entries.append(UpcomingEntry(id: r.id, title: r.title, date: r.scheduledDate,
                                         symbol: scheduled ? "bell.fill" : "bell.slash",
                                         note: scheduled ? "Reminder scheduled on this device" : "Reminder saved, not scheduled yet",
                                         isWarning: !scheduled, libraryID: nil))
        }
        for c in items.libraryItems where c.kind == .calendar && !c.isCompleted {
            if let start = c.dueDate, (c.endDate ?? start) > now {
                entries.append(UpcomingEntry(id: c.id, title: c.title, date: start, symbol: "calendar",
                                             note: "Event", isWarning: false, libraryID: c.id))
            }
        }
        return Array(entries.sorted { $0.date < $1.date }.prefix(5))
    }

    private var recentReceipts: [OrganizationReceipt] {
        Array(items.organizationReceipts.sorted { $0.createdAt > $1.createdAt }.prefix(3))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    StorageBanner()
                    if let warning = model.storageWarning {
                        Text(warning).font(.footnote).foregroundStyle(Theme.warn).organizerCard()
                    }
                    reviewCard
                    quickCommandCard
                    upcomingCard
                    recordingsCard
                    receiptsCard
                }
                .padding(16)
            }
            .background(Theme.surface)
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date(), format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("MixCapture").font(.title.bold()).foregroundStyle(Theme.ink)
            }
            Text("Record or type, then find your organized items here.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var reviewCard: some View {
        let count = items.reviewItems.count
        return NavigationLink {
            ReviewQueueScreen()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: count > 0 ? "exclamationmark.bubble.fill" : "checkmark.seal")
                    .font(.title2)
                    .foregroundStyle(count > 0 ? Theme.warn : Theme.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count > 0 ? "Needs your review" : "Nothing to review")
                        .font(.headline).foregroundStyle(Theme.ink)
                    Text(count > 0 ? "\(count) to review before saving" : "Unclear commands will appear here")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
            }
            .organizerCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.review")
    }

    private var quickCommandCard: some View {
        Button(action: openCommand) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard").foregroundStyle(Theme.teal)
                Text("Type a quick command…").foregroundStyle(.secondary)
                Spacer()
            }
            .organizerCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Type a quick command")
        .accessibilityIdentifier("home.quickCommand")
    }

    private var upcomingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Coming up", symbol: "clock")
                Spacer()
                NavigationLink("All reminders") { RemindersScreen(embedded: true) }
                    .font(.subheadline)
                    .accessibilityIdentifier("home.reminders")
            }
            if upcoming.isEmpty {
                Text("No upcoming reminders or events.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(upcoming) { entry in
                if let libraryID = entry.libraryID {
                    NavigationLink { LibraryDetailView(id: libraryID) } label: { upcomingRow(entry) }
                        .buttonStyle(.plain)
                } else {
                    upcomingRow(entry)
                }
            }
        }
        .organizerCard()
    }

    private func upcomingRow(_ entry: UpcomingEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .foregroundStyle(entry.isWarning ? Theme.warn : Theme.teal)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).foregroundStyle(Theme.ink).lineLimit(2)
                Text("\(shortDateTime(entry.date)) · \(entry.note)")
                    .font(.caption).foregroundStyle(entry.isWarning ? Theme.warn : Color.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var recordingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Recent recordings", symbol: "waveform")
                Spacer()
                NavigationLink("All") { RecordingsListScreen(model: model) }
                    .font(.subheadline)
            }
            if model.records.isEmpty {
                Text("No recordings yet. Tap the microphone to begin.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(model.records.prefix(3)) { record in
                NavigationLink {
                    RecordingDetailScreen(model: model, recordID: record.id)
                } label: {
                    RecordingRowLabel(record: record)
                }
                .buttonStyle(.plain)
                if record.id != model.records.prefix(3).last?.id { Divider() }
            }
        }
        .organizerCard()
    }

    @ViewBuilder
    private var receiptsCard: some View {
        if !recentReceipts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Recently organized", symbol: "square.stack.3d.up")
                ForEach(recentReceipts) { ReceiptCard(receipt: $0) }
            }
        }
    }
}

// MARK: - Library

struct LibraryScreen: View {
    let dock: RecordDock
    private let items = LocalItemsModel.shared
    @State private var search = ""
    @State private var kindFilter: OrganizerKind?
    @State private var showingAdd = false
    @State private var error: String?

    private func order(_ a: OrganizerItem, _ b: OrganizerItem) -> Bool {
        if a.isCompleted != b.isCompleted { return !a.isCompleted }
        return a.createdAt > b.createdAt
    }

    private func matches(_ item: OrganizerItem) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = [item.title, item.body, item.collection] + item.ingredients + item.steps
        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private var filtered: [OrganizerItem] {
        items.libraryItems.filter { (kindFilter == nil || $0.kind == kindFilter) && matches($0) }
    }

    private var groups: [(name: String, rows: [OrganizerItem])] {
        let dict = Dictionary(grouping: filtered) { $0.collection.trimmingCharacters(in: .whitespacesAndNewlines) }
        let names = dict.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return names.map { (name: $0, rows: (dict[$0] ?? []).sorted(by: order)) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chips
                StorageBanner().padding(.horizontal, 16).padding(.bottom, 8)
                list
            }
            .background(Theme.surface)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search your library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add item", systemImage: "plus") { showingAdd = true }
                        .disabled(items.storageError != nil)
                        .accessibilityIdentifier("library.add")
                }
            }
            .sheet(isPresented: $showingAdd) { LibraryEditor(existing: nil, initialKind: kindFilter ?? .note) }
            .alert("Could not save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", symbol: "square.grid.2x2", selected: kindFilter == nil, id: "library.filter.all") {
                    kindFilter = nil
                }
                ForEach(OrganizerKind.allCases) { kind in
                    chip(title: kind.label, symbol: kind.uiSymbol, selected: kindFilter == kind,
                         id: "library.filter.\(kind.rawValue)") {
                        kindFilter = (kindFilter == kind) ? nil : kind
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .accessibilityIdentifier("library.filters")
    }

    private func chip(title: String, symbol: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .background(selected ? Theme.teal : Theme.card, in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline))
                .foregroundStyle(selected ? Theme.onTeal : Theme.ink)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var list: some View {
        if items.libraryItems.isEmpty {
            ContentUnavailableView("Your library is empty", systemImage: "books.vertical",
                                   description: Text("Record or type a command, or tap + to add an item."))
                .frame(maxHeight: .infinity)
        } else if filtered.isEmpty {
            if search.isEmpty {
                ContentUnavailableView("No items in this section", systemImage: "tray")
                    .frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: search).frame(maxHeight: .infinity)
            }
        } else {
            List {
                ForEach(groups, id: \.name) { group in
                    Section {
                        ForEach(group.rows) { row($0) }
                    } header: {
                        Label(group.name.isEmpty ? "Ungrouped" : group.name,
                              systemImage: group.name.isEmpty ? "tray" : "folder")
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ item: OrganizerItem) -> some View {
        HStack(spacing: 12) {
            if item.kind == .task || item.kind == .shopping {
                Button {
                    do { try items.toggleLibrary(id: item.id) } catch { self.error = error.localizedDescription }
                } label: {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(Theme.teal)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .disabled(items.storageError != nil)
                .accessibilityLabel("\(item.title) — \(item.isCompleted ? "Mark incomplete" : "Mark complete")")
            } else {
                Image(systemName: item.kind.uiSymbol).foregroundStyle(Theme.teal).frame(width: 24)
                    .accessibilityHidden(true)
            }
            NavigationLink {
                LibraryDetailView(id: item.id)
            } label: {
                LibraryRowText(item: item)
            }
            .accessibilityLabel("Open \(item.title)")
            .accessibilityIdentifier("library.open.\(item.id.uuidString)")
        }
    }
}

private func scheduleText(_ item: OrganizerItem) -> String? {
    switch (item.dueDate, item.endDate) {
    case (let start?, let end?): return "\(shortDateTime(start)) → \(shortDateTime(end))"
    case (let start?, nil): return shortDateTime(start)
    default: return nil
    }
}

private struct LibraryRowText: View {
    let item: OrganizerItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .strikethrough(item.isCompleted)
                .foregroundStyle(item.isCompleted ? .secondary : Theme.ink)
                .lineLimit(2)
            HStack(spacing: 4) {
                Text(item.kind.label)
                if let when = scheduleText(item) { Text("·"); Text(when) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !item.body.isEmpty, item.body != item.title {
                Text(item.body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Library detail

struct LibraryDetailView: View {
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    private let items = LocalItemsModel.shared
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var error: String?

    private var item: OrganizerItem? { items.libraryItems.first { $0.id == id } }

    private func removalNote(_ item: OrganizerItem) -> String {
        if item.kind == .calendar || !(item.externalCalendarID ?? "").isEmpty {
            return "This removes the item from the app only. Its iPhone calendar event stays in place and can be deleted in Calendar."
        }
        return "This removes the item from the app. The recording and original text stay unchanged."
    }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        StorageBanner()
                        header(item)
                        if !item.body.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionTitle(title: "Original text")
                                Text(item.body).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .organizerCard()
                        }
                        if !item.ingredients.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                SectionTitle(title: "Ingredients", symbol: "list.bullet")
                                ForEach(Array(item.ingredients.enumerated()), id: \.offset) { _, line in
                                    Label(line, systemImage: "circle.fill")
                                        .labelStyle(BulletLabelStyle())
                                        .textSelection(.enabled)
                                }
                            }
                            .organizerCard()
                        }
                        if !item.steps.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionTitle(title: "Steps", symbol: "list.number")
                                ForEach(Array(item.steps.enumerated()), id: \.offset) { index, line in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(index + 1).").foregroundStyle(Theme.teal).monospacedDigit()
                                        Text(line).textSelection(.enabled)
                                    }
                                }
                            }
                            .organizerCard()
                        }
                        if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Label("Delete from app", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(items.storageError != nil)
                        .accessibilityIdentifier("library.delete")
                        .confirmationDialog("Delete from app?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                            Button("Delete from app", role: .destructive) { delete() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(removalNote(item))
                        }
                    }
                    .padding(16)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { editing = true }
                            .disabled(items.storageError != nil)
                            .accessibilityIdentifier("library.edit")
                    }
                }
                .sheet(isPresented: $editing) { LibraryEditor(existing: item, initialKind: item.kind) }
            } else {
                ContentUnavailableView("Item not found", systemImage: "questionmark.folder")
            }
        }
        .background(Theme.surface)
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ item: OrganizerItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: item.kind.uiSymbol).foregroundStyle(Theme.teal)
                Text(item.kind.label).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(item.title).font(.title3.bold()).foregroundStyle(Theme.ink).textSelection(.enabled)
            if !item.collection.isEmpty {
                Label(item.collection, systemImage: "folder").font(.subheadline).foregroundStyle(.secondary)
            }
            if let when = scheduleText(item) {
                Label(when, systemImage: "clock").font(.subheadline)
            }
            if item.kind == .task || item.kind == .shopping {
                Button {
                    do { try items.toggleLibrary(id: item.id); error = nil } catch { self.error = error.localizedDescription }
                } label: {
                    Label(item.isCompleted ? "Mark incomplete" : "Mark complete",
                          systemImage: item.isCompleted ? "arrow.uturn.backward" : "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(items.storageError != nil)
                .accessibilityIdentifier("library.toggle")
            }
            if let ext = item.externalCalendarID, !ext.isEmpty {
                Text("Linked to an iPhone calendar event. Editing the time here does not automatically update that event.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .organizerCard()
    }

    private func delete() {
        do {
            try items.deleteLibrary(id: id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(Theme.teal)
            configuration.title
        }
    }
}

// MARK: - Library editor

struct LibraryEditor: View {
    let existing: OrganizerItem?
    @Environment(\.dismiss) private var dismiss
    private let items = LocalItemsModel.shared

    @State private var kind: OrganizerKind
    @State private var title: String
    @State private var bodyText: String
    @State private var collection: String
    @State private var start: Date?
    @State private var end: Date?
    @State private var ingredientsText: String
    @State private var stepsText: String
    @State private var error: String?

    init(existing: OrganizerItem?, initialKind: OrganizerKind) {
        self.existing = existing
        _kind = State(initialValue: existing?.kind ?? initialKind)
        _title = State(initialValue: existing?.title ?? "")
        _bodyText = State(initialValue: existing?.body ?? "")
        _collection = State(initialValue: existing?.collection ?? "")
        _start = State(initialValue: existing?.dueDate)
        _end = State(initialValue: existing?.endDate)
        _ingredientsText = State(initialValue: (existing?.ingredients ?? []).joined(separator: "\n"))
        _stepsText = State(initialValue: (existing?.steps ?? []).joined(separator: "\n"))
    }

    private var collections: [String] {
        Array(Set(items.libraryItems.map(\.collection).filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var validation: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "A title is required." }
        if kind == .calendar {
            guard let start, let end else { return "Choose the event start and end times." }
            if end <= start { return "The end time must be after the start time." }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if items.storageError != nil {
                    Section { StorageBanner().listRowInsets(EdgeInsets()) }
                }
                Section {
                    if existing == nil {
                        Picker("Type", selection: $kind) {
                            ForEach(OrganizerKind.allCases) { Label($0.label, systemImage: $0.uiSymbol).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("editor.kind")
                    }
                    TextField("Title", text: $title, axis: .vertical)
                        .accessibilityIdentifier("editor.title")
                    HStack {
                        TextField("Collection or project (optional)", text: $collection)
                        if !collections.isEmpty {
                            Menu {
                                ForEach(collections, id: \.self) { name in
                                    Button(name) { collection = name }
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .accessibilityLabel("Choose an existing collection")
                        }
                    }
                }
                Section("Text") {
                    if existing?.sourceCaptureID != nil {
                        Text(bodyText).textSelection(.enabled)
                    } else {
                        TextField("Details", text: $bodyText, axis: .vertical).lineLimit(3...10)
                    }
                }
                if kind == .task {
                    Section("Date and time") {
                        OptionalDateRow(title: "Set a date and time", date: $start)
                    }
                }
                if kind == .calendar {
                    Section {
                        OptionalDateRow(title: "Set start time", date: $start)
                        OptionalDateRow(title: "Set end time", date: $end,
                                        fallback: { (start ?? Date()).addingTimeInterval(3600) })
                    } header: {
                        Text("Event time")
                    } footer: {
                        Text("Choose both the start and end times for the event.")
                    }
                }
                if kind == .recipe {
                    Section {
                        TextField("Ingredients, one per line", text: $ingredientsText, axis: .vertical).lineLimit(3...12)
                    } header: { Text("Ingredients") }
                    Section {
                        TextField("Steps, one per line", text: $stepsText, axis: .vertical).lineLimit(3...12)
                    } header: { Text("Steps") }
                }
                if let message = validation {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "New item" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(validation != nil || items.storageError != nil)
                        .accessibilityIdentifier("editor.save")
                }
            }
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validation == nil else { return }
        var item = existing ?? OrganizerItem(kind: kind, title: cleanTitle, body: bodyText)
        item.kind = kind
        item.title = cleanTitle
        item.body = bodyText
        item.collection = collection.trimmingCharacters(in: .whitespacesAndNewlines)
        item.dueDate = (kind == .task || kind == .calendar) ? start : nil
        item.endDate = kind == .calendar ? end : nil
        if kind == .recipe {
            item.ingredients = parseLines(ingredientsText, original: existing?.ingredients ?? [])
            item.steps = parseLines(stepsText, original: existing?.steps ?? [])
        }
        do {
            try items.upsertLibrary(item)
            if kind == .calendar { Task { await CalendarBridge.shared.syncPending() } }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Review queue

struct ReviewQueueScreen: View {
    private let items = LocalItemsModel.shared

    private var reviewReceipts: [OrganizationReceipt] {
        items.organizationReceipts.filter { $0.status == .review }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            if items.storageError != nil {
                Section { StorageBanner().listRowInsets(EdgeInsets()) }
            }
            if items.reviewItems.isEmpty {
                Section {
                    ContentUnavailableView("Nothing to review", systemImage: "checkmark.seal",
                                           description: Text("Unclear commands appear here before they are saved."))
                }
            } else {
                Section {
                    ForEach(items.reviewItems) { draft in
                        NavigationLink {
                            ReviewEditor(draft: draft)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(draft.kind.label, systemImage: draft.kind.uiSymbol)
                                    .font(.caption).foregroundStyle(Theme.teal)
                                Text(draft.title).lineLimit(2)
                                if let reason = draft.reason {
                                    Text(reason).font(.caption).foregroundStyle(Theme.warn).lineLimit(2)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Review and save each item to add it to your library. To remove a source and its items, use Undo on its card below.")
                }
            }
            if !reviewReceipts.isEmpty {
                Section("Sources needing review") {
                    ForEach(reviewReceipts) { ReceiptCard(receipt: $0).listRowInsets(EdgeInsets()) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ReviewEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let items = LocalItemsModel.shared
    private let originalIngredients: [String]
    private let originalSteps: [String]
    @State private var draft: OrganizationDraft
    @State private var ingredientsText: String
    @State private var stepsText: String
    @State private var saving = false
    @State private var error: String?

    init(draft: OrganizationDraft) {
        _draft = State(initialValue: draft)
        originalIngredients = draft.ingredients
        originalSteps = draft.steps
        _ingredientsText = State(initialValue: draft.ingredients.joined(separator: "\n"))
        _stepsText = State(initialValue: draft.steps.joined(separator: "\n"))
    }

    private var validation: String? {
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "A title is required." }
        switch draft.kind {
        case .expense:
            if parseAmount(draft.amountText) == nil { return "Enter a valid amount with up to two decimal places." }
        case .reminder:
            if draft.dueDate == nil { return "Choose a reminder date." }
        case .calendar:
            guard let start = draft.dueDate, let end = draft.endDate else { return "Choose the event start and end times." }
            if end <= start { return "The end time must be after the start time." }
        default: break
        }
        return nil
    }

    var body: some View {
        Form {
            if items.storageError != nil {
                Section { StorageBanner().listRowInsets(EdgeInsets()) }
            }
            if let reason = draft.reason {
                Section("Why this needs review") {
                    Label(reason, systemImage: "exclamationmark.circle").foregroundStyle(Theme.warn)
                }
            }
            Section {
                Picker("Type", selection: $draft.kind) {
                    ForEach(OrganizationKind.allCases) { Label($0.label, systemImage: $0.uiSymbol).tag($0) }
                }
                TextField("Title", text: $draft.title, axis: .vertical)
                TextField("Collection or project (optional)", text: $draft.collection)
            }
            Section("Original text") {
                Text(draft.body).textSelection(.enabled)
            }
            if draft.kind == .expense {
                Section("Expense") {
                    DatePicker("Expense date", selection: Binding(
                        get: { draft.dueDate ?? draft.createdAt }, set: { draft.dueDate = $0 }),
                               displayedComponents: .date)
                    TextField("Amount (e.g. 120.50)", text: $draft.amountText)
                        .keyboardType(.decimalPad)
                        .environment(\.layoutDirection, .leftToRight)
                    Picker("Currency", selection: $draft.currency) {
                        ForEach(Currency.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Category", selection: $draft.category) {
                        ForEach(ExpenseCategory.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            if draft.kind == .reminder || draft.kind == .task || draft.kind == .calendar {
                Section("Dates and times") {
                    OptionalDateRow(title: draft.kind == .calendar ? "Set start time" : "Set a date and time", date: $draft.dueDate)
                    if draft.kind == .calendar {
                        OptionalDateRow(title: "Set end time", date: $draft.endDate,
                                        fallback: { (draft.dueDate ?? Date()).addingTimeInterval(3600) })
                    }
                }
            }
            if draft.kind == .recipe || !originalIngredients.isEmpty || !originalSteps.isEmpty {
                Section("Ingredients") {
                    TextField("One per line", text: $ingredientsText, axis: .vertical).lineLimit(3...12)
                }
                Section("Steps") {
                    TextField("One per line", text: $stepsText, axis: .vertical).lineLimit(3...12)
                }
            }
            if let message = validation {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("review.validation") }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(saving || validation != nil || items.storageError != nil)
                    .accessibilityIdentifier("review.save")
            }
        }
    }

    private func save() {
        guard !saving, validation == nil else { return }
        saving = true
        error = nil
        var final = draft
        final.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        final.collection = draft.collection.trimmingCharacters(in: .whitespacesAndNewlines)
        final.ingredients = parseLines(ingredientsText, original: originalIngredients)
        final.steps = parseLines(stepsText, original: originalSteps)
        if final.kind != .expense { final.amountText = "" }
        final.requiresReview = false
        let toSave = final
        Task {
            defer { saving = false }
            do {
                try await items.applyReview(toSave)
                await CalendarBridge.shared.syncPending()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Settings

struct SettingsScreen: View {
    @Bindable var model: CaptureModel
    let dock: RecordDock
    private let items = LocalItemsModel.shared
    private let bridge = CalendarBridge.shared
    @State private var importing = false
    @State private var importResult: (text: String, isError: Bool)?
    @State private var calendarError: String?

    private var buildLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (build \(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                if items.storageError != nil || items.saveError != nil {
                    Section { StorageBanner().listRowInsets(EdgeInsets()) }
                }
                organizationSection
                calendarSection
                backupSection
                shortcutSection
                examplesSection
                privacySection
                Section {
                    NavigationLink {
                        ContentView(model: model, embedded: true)
                    } label: {
                        Label("Diagnostics and transcription", systemImage: "stethoscope")
                    }
                    .accessibilityIdentifier("settings.diagnostics")
                    LabeledContent("Version", value: buildLabel)
                } footer: {
                    Text("MixCapture")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): importBackup(url)
                case .failure(let error): importResult = (error.localizedDescription, true)
                }
            }
        }
    }

    private var organizationSection: some View {
        Section {
            Toggle("Organize automatically after transcription", isOn: Binding(
                get: { items.automaticOrganizationEnabled },
                set: { items.automaticOrganizationEnabled = $0 }
            ))
            .disabled(items.storageError != nil)
            .accessibilityIdentifier("settings.autoOrganize")
        } header: {
            Text("Organization")
        } footer: {
            Text("When enabled, on-device rules organize transcripts into expenses, reminders, lists, and recipes. Unclear commands wait for your confirmation in Review.")
        }
    }

    private var calendarSection: some View {
        Section {
            LabeledContent("Status", value: bridge.enabled ? "Automatic additions enabled" : "Automatic additions paused")
            if let message = bridge.statusMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if let calendarError {
                Text(calendarError).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
            }
            if bridge.isBusy {
                HStack { ProgressView(); Text("Syncing…").foregroundStyle(.secondary) }
            }
            if bridge.enabled {
                Button("Disconnect calendar", role: .destructive) {
                    bridge.disconnect()
                    calendarError = nil
                }
                .accessibilityIdentifier("settings.calendarDisconnect")
            } else {
                Button("Connect iPhone calendar") {
                    Task {
                        do {
                            try await bridge.connectAndSync()
                            calendarError = nil
                        } catch {
                            calendarError = error.localizedDescription
                        }
                    }
                }
                .disabled(bridge.isBusy)
                .accessibilityIdentifier("settings.calendarConnect")
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Connecting adds event titles and times to your default calendar. iOS may sync them through your enabled calendar accounts. Original text stays in MixCapture. Reminders use local notifications and do not sync with Apple Reminders.")
        }
    }

    private var backupSection: some View {
        Section {
            ShareLink(item: OrganizerBackup(contents: items.exportJSON()), preview: SharePreview("MixCapture backup (JSON)")) {
                Label("Export JSON backup", systemImage: "square.and.arrow.up")
            }
            .disabled(items.storageError != nil)
            .accessibilityIdentifier("settings.backup")
            Button {
                importing = true
            } label: {
                Label("Import JSON backup", systemImage: "square.and.arrow.down")
            }
            .disabled(items.storageError != nil)
            .accessibilityIdentifier("settings.import")
            if let importResult {
                Text(importResult.text).font(.footnote)
                    .foregroundStyle(importResult.isError ? Color.red : Theme.teal)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Import only adds new items; existing items stay unchanged. JSON does not include audio files. Importing does not create notifications or calendar events.")
        }
    }

    private var shortcutSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Record with a double tap on the back of your iPhone:").font(.subheadline.weight(.semibold))
                Text("1. Open Settings › Accessibility › Touch › Back Tap.")
                Text("2. Choose Double Tap and select a MixCapture shortcut: Toggle Recording to start and stop, or Start Recording to start only.")
                Text("3. iOS may ask you to open the app or unlock your iPhone before recording starts.")
                Text("Alternatively, add an Open URLs action in Shortcuts with this URL:")
                Text("mixcapture://toggle")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.footnote)
        } header: {
            Text("Recording shortcut")
        }
    }

    private var examplesSection: some View {
        Section {
            CommandExamples()
        } header: {
            Text("Command examples")
        } footer: {
            Text("Type or speak in Arabic, English, or a mix. Unclear commands go to Review.")
        }
    }

    private var privacySection: some View {
        Section {
            Label("Transcription and organization stay on device; audio is not uploaded. Calendar connection is optional, and calendar syncing follows your iOS accounts.", systemImage: "lock.shield")
                .font(.footnote)
        } header: {
            Text("Privacy")
        }
    }

    private func importBackup(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try items.mergeBackup(data: data)
            importResult = ("Backup merged. Existing items are unchanged; only new items were added.", false)
        } catch {
            importResult = (error.localizedDescription, true)
        }
    }
}
