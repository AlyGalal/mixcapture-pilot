import SwiftUI

@main
struct MixCaptureApp: App {
    @State private var model = CaptureModel.shared
    @Environment(\.scenePhase) private var scenePhase

    private var simulatorAppearance: ColorScheme? {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return ProcessInfo.processInfo.arguments.contains("--ui-dark") ? .dark : .light
        }
        #endif
        return nil
    }

    var body: some Scene {
        WindowGroup {
            OrganizerShell(model: model)
                .tint(Theme.teal)
                .preferredColorScheme(simulatorAppearance)
                .environment(\.layoutDirection, .leftToRight)
                .environment(\.locale, Locale(identifier: "en_US"))
                .task { await SimulatorFixtures.installIfRequested() }
                .onOpenURL { url in
                    // mixcapture://record — same queued start path as the App Shortcut.
                    // OrganizerShell reacts to model.isWaitingToStart/isRecording (home + sheet).
                    if url.scheme == "mixcapture", url.host() == "record" {
                        model.requestStart()
                    } else if url.scheme == "mixcapture", url.host() == "toggle" {
                        model.toggleRecording()
                    }
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.sceneChanged(isActive: phase == .active, isBackground: phase == .background)
            if phase == .active {
                Task {
                    await LocalItemsModel.shared.reconcile()
                    await CalendarBridge.shared.syncPending()
                }
            }
        }
    }
}

/// Diagnostics / engine lab. Reached from Settings (`embedded: true`) inside its NavigationStack.
struct ContentView: View {
    @Bindable var model: CaptureModel
    var embedded = false

    var body: some View {
        if embedded {
            list
        } else {
            NavigationStack { list }
        }
    }

    private var list: some View {
        List {
            captureSection
            testCaseSection
            engineSection
            recordingsSection
            exportSection
        }
        .navigationTitle("Diagnostics")
    }

    private var statusLine: (text: String, symbol: String, isError: Bool) {
        switch model.status {
        case .idle: return ("Ready to record", "checkmark.circle", false)
        case .waitingToStart: return ("Waiting for the app and microphone permission. Recording has not started…", "ear", false)
        case .recording: return ("Recording…", "record.circle", false)
        case .processing: return ("Transcribing on device…", "waveform", false)
        case .saved(let message): return (message, "tray.and.arrow.down", false)
        case .failed(let message): return (message, "exclamationmark.triangle", true)
        }
    }

    private var captureSection: some View {
        Section {
            Label(statusLine.text, systemImage: statusLine.symbol)
                .font(.headline)
                .foregroundStyle(statusLine.isError ? Color.red : Color.primary)
                .accessibilityLabel("Status: \(statusLine.text)")

            if let active = model.activeRecord {
                Text(active.recordedAt, style: .timer)
                    .font(.largeTitle.monospacedDigit())
                    .accessibilityLabel("Recording duration")
                Button(role: .destructive) {
                    model.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if model.isWaitingToStart {
                Button("Cancel recording request") { model.cancelPendingStart() }
                    .buttonStyle(.bordered)
            } else {
                Button {
                    model.requestStart()
                } label: {
                    Label("Record", systemImage: "mic.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Picker("Transcription engine", selection: $model.selectedLocale) {
                ForEach(PilotLocale.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.menu)

            if let warning = model.storageWarning {
                Text(warning).foregroundStyle(.orange)
            }
        } footer: {
            Text("Mixed Arabic+English uses Whisper on device for both languages. Apple engines are available for comparison on the same audio. Review words and numbers before saving an expense or reminder.")
        }
    }

    private var testCaseSection: some View {
        Section("Test case") {
            Picker("Recording test case", selection: $model.selectedCaseID) {
                Text("None").tag(String?.none)
                ForEach(TestCase.all) { testCase in
                    Text(testCase.id).tag(Optional(testCase.id))
                }
            }
            if let testCase = TestCase.find(model.selectedCaseID) {
                Text(testCase.prompt)
                    .font(.title3)
                    .textSelection(.enabled)
                Text(testCase.focus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var engineSection: some View {
        Section {
            LabeledContent("Device", value: model.deviceDescription)
            LabeledContent("OS", value: model.osDescription)
            LabeledContent("Engine", value: LocalTranscriber.engineLabel(for: model.selectedLocale))
            ForEach(PilotLocale.allCases) { locale in
                VStack(alignment: .leading, spacing: 2) {
                    Text(locale.label).font(.headline)
                    if let report = model.assetReports[locale] {
                        if locale == .mixedArabicEnglish {
                            Text("\(report.resolved ?? "?") · Egyptian Arabic+English: \(report.status)")
                                .font(.callout)
                                .foregroundStyle(report.status == "installed" ? Color.primary : Color.red)
                        } else {
                            Text("resolved: \(report.resolved ?? "unsupported") · assets: \(report.status)")
                                .font(.callout)
                        }
                    } else {
                        Text("Not checked yet").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("The Egyptian Arabic+English model is bundled (~264 MB), with no download or connection needed during transcription. It may take longer than Apple; processing time appears with the result.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach([PilotLocale.arabicEgypt, PilotLocale.englishUS]) { locale in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Prepare \(locale.label)") { model.prepare(locale) }
                            .buttonStyle(.bordered)
                            .disabled(model.preparingLocale != nil)
                        if model.preparingLocale == locale {
                            ProgressView()
                        }
                    }
                    if model.preparingLocale == locale {
                        Text("Preparing \(locale.rawValue)…").font(.callout).foregroundStyle(.secondary)
                    } else if let note = model.prepareNotes[locale] {
                        Text(note.text)
                            .font(.callout)
                            .foregroundStyle(note.isError ? Color.red : Color.green)
                    }
                }
            }
            Button("Refresh model status") { model.refreshAssetStatus() }
                .buttonStyle(.bordered)
        } header: {
            Text("On-device engine")
        } footer: {
            Text("Apple models download only when you tap Prepare Apple. Whisper needs no download. Transcription stays on device, with no cloud upload.")
        }
    }

    private var recordingsSection: some View {
        Section("Recent recordings") {
            if model.records.isEmpty {
                Text("No recordings yet.").foregroundStyle(.secondary)
            }
            ForEach(model.records) { record in
                RecordRow(record: record, model: model)
            }
        }
    }

    private var exportSection: some View {
        Section {
            ShareLink(item: model.resultsJSON(), preview: SharePreview("MixCapture results JSON")) {
                Label("Export results JSON", systemImage: "square.and.arrow.up")
            }
            .disabled(model.records.isEmpty)
        } footer: {
            Text("Sharing is manual, with no automatic upload. Assessments are manual; no accuracy score is generated.")
        }
    }
}

struct RecordRow: View {
    let record: CaptureRecord
    let model: CaptureModel
    @State private var showingExpense = false
    @State private var showingReminder = false

    private var statusLabel: String {
        switch record.status {
        case .recording: return "Recording"
        case .interrupted: return "Interrupted"
        case .pendingTranscription: return "Waiting to transcribe"
        case .transcribing: return "Transcribing"
        case .transcribed: return "Transcribed"
        case .failed: return "Failed"
        }
    }

    private var details: String {
        let duration = record.durationSeconds.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US")))
        var parts = ["Duration \(duration) s", "requested \(record.requestedLocale)"]
        if let resolved = record.resolvedLocale { parts.append("transcript locale \(resolved)") }
        if let engine = record.engine { parts.append(engine) }
        if let seconds = record.processingSeconds {
            parts.append("processing \(seconds.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US")))) s")
        }
        if record.wasInterrupted { parts.append("interrupted") }
        return parts.joined(separator: " · ")
    }

    private func snapshotDetails(_ snapshot: TranscriptSnapshot) -> String {
        var parts = [snapshot.engine ?? "engine ?", "transcript locale \(snapshot.resolvedLocale ?? "?")"]
        if let seconds = snapshot.processingSeconds {
            parts.append("processing \(seconds.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US")))) s")
        }
        parts.append("Assessment: \(snapshot.manualAssessment.rawValue)")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.recordedAt, format: .dateTime.day().month().hour().minute().second())
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(record.status == .failed ? Color.red : Color.secondary)
            }
            if let caseID = record.testCaseID {
                Text("case: \(caseID)").font(.caption.monospaced())
            }
            if let prompt = record.testPrompt {
                Text("Prompt: \(prompt)").foregroundStyle(.secondary)
            }
            if let transcript = record.transcript {
                Text("\(record.status == .transcribed ? "Result" : "Last successful text from an earlier attempt"): \(transcript)")
                    .textSelection(.enabled)
            }
            if let error = record.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            Text(details).font(.caption).foregroundStyle(.secondary)

            HStack {
                Button {
                    model.togglePlayback(record)
                } label: {
                    Label(model.playingID == record.id ? "Stop" : "Play",
                          systemImage: model.playingID == record.id ? "stop.fill" : "play.fill")
                }
                .disabled(model.isRecording)

                Button {
                    model.retryTranscription(record.id)
                } label: {
                    Label("Transcribe again (\(model.selectedLocale.rawValue))", systemImage: "arrow.clockwise")
                }
                .disabled(!record.canRetry)

                ShareLink(item: model.diagnosticJSON(for: record),
                          preview: SharePreview("MixCapture diagnostic")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .font(.callout)

            if record.transcript != nil {
                HStack {
                    Button("Save as expense", systemImage: "creditcard") { showingExpense = true }
                    Button("Create reminder", systemImage: "bell.badge") { showingReminder = true }
                }
                .buttonStyle(.bordered)
                Picker("Manual assessment", selection: Binding(
                    get: { record.assessment },
                    set: { model.setAssessment($0, for: record.id) }
                )) {
                    Text("Not assessed").tag(ManualAssessment.unassessed)
                    Text("correct ✓").tag(ManualAssessment.correct)
                    Text("needs work").tag(ManualAssessment.needsWork)
                }
                .pickerStyle(.segmented)
            }

            if let history = record.transcriptHistory, !history.isEmpty {
                DisclosureGroup("Saved previous results (\(history.count))") {
                    ForEach(Array(history.enumerated().reversed()), id: \.offset) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshotDetails(item.element)).font(.caption).foregroundStyle(.secondary)
                            Text(item.element.text).textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingExpense) { ExpenseEditor(source: record) }
        .sheet(isPresented: $showingReminder) { ReminderEditor(source: record) }
    }
}
