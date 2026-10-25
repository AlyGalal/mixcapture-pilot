import SwiftUI

@main
struct MixCaptureApp: App {
    @State private var model = CaptureModel.shared
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                ContentView(model: model)
                    .tabItem { Label("التسجيل", systemImage: "mic") }.tag(0)
                ExpensesScreen()
                    .tabItem { Label("المصروفات", systemImage: "creditcard") }.tag(1)
                RemindersScreen()
                    .tabItem { Label("التذكيرات", systemImage: "bell") }.tag(2)
            }
                .environment(\.layoutDirection, .rightToLeft)
                .onChange(of: model.isWaitingToStart) { _, waiting in
                    if waiting { selectedTab = 0 }
                }
                .onChange(of: model.isRecording) { _, recording in
                    if recording { selectedTab = 0 }
                }
                .onOpenURL { url in
                    // mixcapture://record — same queued start path as the App Shortcut.
                    if url.scheme == "mixcapture", url.host() == "record" {
                        selectedTab = 0
                        model.requestStart()
                    }
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.sceneChanged(isActive: phase == .active, isBackground: phase == .background)
            if phase == .active { Task { await LocalItemsModel.shared.reconcile() } }
        }
    }
}

struct ContentView: View {
    @Bindable var model: CaptureModel

    var body: some View {
        NavigationStack {
            List {
                captureSection
                testCaseSection
                engineSection
                recordingsSection
                exportSection
            }
            .navigationTitle("MixCapture Pilot")
        }
    }

    private var statusLine: (text: String, symbol: String, isError: Bool) {
        switch model.status {
        case .idle: return ("جاهز للتسجيل", "checkmark.circle", false)
        case .waitingToStart: return ("بانتظار فتح التطبيق وإذن الميكروفون؛ التسجيل لم يبدأ…", "ear", false)
        case .recording: return ("جاري التسجيل (recording)…", "record.circle", false)
        case .processing: return ("جاري التفريغ المحلي (processing)…", "waveform", false)
        case .saved(let message): return (message, "tray.and.arrow.down", false)
        case .failed(let message): return (message, "exclamationmark.triangle", true)
        }
    }

    private var captureSection: some View {
        Section {
            Label(statusLine.text, systemImage: statusLine.symbol)
                .font(.headline)
                .foregroundStyle(statusLine.isError ? Color.red : Color.primary)
                .accessibilityLabel("الحالة: \(statusLine.text)")

            if let active = model.activeRecord {
                Text(active.recordedAt, style: .timer)
                    .font(.largeTitle.monospacedDigit())
                    .accessibilityLabel("مدة التسجيل")
                Button(role: .destructive) {
                    model.stopRecording()
                } label: {
                    Label("إيقاف التسجيل (Stop)", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else if model.isWaitingToStart {
                Button("إلغاء طلب البدء") { model.cancelPendingStart() }
                    .buttonStyle(.bordered)
            } else {
                Button {
                    model.requestStart()
                } label: {
                    Label("ابدأ التسجيل (Start Recording)", systemImage: "mic.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Picker("محرك التفريغ (engine)", selection: $model.selectedLocale) {
                ForEach(PilotLocale.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.menu)

            if let warning = model.storageWarning {
                Text(warning).foregroundStyle(.orange)
            }
        } footer: {
            Text("Mixed Arabic+English يستخدم Whisper محلياً للغتين. خيارات Apple للمقارنة على نفس الصوت. راجع الكلمات والأرقام قبل حفظها كمصروف أو تذكير.")
        }
    }

    private var testCaseSection: some View {
        Section("حالة الاختبار (test case)") {
            Picker("الحالة المرفقة بالتسجيل", selection: $model.selectedCaseID) {
                Text("بدون حالة").tag(String?.none)
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
                            Text("resolved: \(report.resolved ?? "غير مدعوم") · assets: \(report.status)")
                                .font(.callout)
                        }
                    } else {
                        Text("لم يتم الفحص بعد").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("نموذج المصري والإنجليزي جاهز داخل التطبيق (~264 MB)، بلا تنزيل أو اتصال أثناء التفريغ. قد يستغرق وقتاً أطول من Apple؛ سيظهر زمن المعالجة مع النتيجة.")
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
                        Text("جاري تجهيز \(locale.rawValue)…").font(.callout).foregroundStyle(.secondary)
                    } else if let note = model.prepareNotes[locale] {
                        Text(note.text)
                            .font(.callout)
                            .foregroundStyle(note.isError ? Color.red : Color.green)
                    }
                }
            }
            Button("تحديث حالة assets") { model.refreshAssetStatus() }
                .buttonStyle(.bordered)
        } header: {
            Text("المحرك المحلي (local engine)")
        } footer: {
            Text("تنزيل assets الخاصة بـApple يحدث فقط عند الضغط على Prepare Apple. Whisper لا ينزّل شيئاً. التفريغ على الجهاز فقط، بدون cloud أو رفع.")
        }
    }

    private var recordingsSection: some View {
        Section("التسجيلات الأخيرة") {
            if model.records.isEmpty {
                Text("لا توجد تسجيلات بعد.").foregroundStyle(.secondary)
            }
            ForEach(model.records) { record in
                RecordRow(record: record, model: model)
            }
        }
    }

    private var exportSection: some View {
        Section {
            ShareLink(item: model.resultsJSON(), preview: SharePreview("MixCapture results JSON")) {
                Label("تصدير النتائج JSON", systemImage: "square.and.arrow.up")
            }
            .disabled(model.records.isEmpty)
        } footer: {
            Text("المشاركة يدوية فقط، بدون رفع تلقائي. التقييم يدوي؛ لا توجد نسبة دقة محسوبة.")
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
        case .recording: return "يسجّل"
        case .interrupted: return "انقطع"
        case .pendingTranscription: return "بانتظار التفريغ"
        case .transcribing: return "جاري التفريغ"
        case .transcribed: return "تم التفريغ"
        case .failed: return "فشل"
        }
    }

    private var details: String {
        let duration = record.durationSeconds.formatted(.number.precision(.fractionLength(1)))
        var parts = ["مدة \(duration) s", "requested \(record.requestedLocale)"]
        if let resolved = record.resolvedLocale { parts.append("transcript locale \(resolved)") }
        if let engine = record.engine { parts.append(engine) }
        if let seconds = record.processingSeconds {
            parts.append("processing \(seconds.formatted(.number.precision(.fractionLength(1)))) s")
        }
        if record.wasInterrupted { parts.append("interrupted") }
        return parts.joined(separator: " · ")
    }

    private func snapshotDetails(_ snapshot: TranscriptSnapshot) -> String {
        var parts = [snapshot.engine ?? "engine ?", "transcript locale \(snapshot.resolvedLocale ?? "?")"]
        if let seconds = snapshot.processingSeconds {
            parts.append("processing \(seconds.formatted(.number.precision(.fractionLength(1)))) s")
        }
        parts.append("تقييم: \(snapshot.manualAssessment.rawValue)")
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
                Text("المطلوب: \(prompt)").foregroundStyle(.secondary)
            }
            if let transcript = record.transcript {
                Text("\(record.status == .transcribed ? "النتيجة" : "آخر نص ناجح — من محاولة سابقة"): \(transcript)")
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
                    Label(model.playingID == record.id ? "إيقاف" : "تشغيل",
                          systemImage: model.playingID == record.id ? "stop.fill" : "play.fill")
                }
                .disabled(model.isRecording)

                Button {
                    model.retryTranscription(record.id)
                } label: {
                    Label("أعد التفريغ (\(model.selectedLocale.rawValue))", systemImage: "arrow.clockwise")
                }
                .disabled(!record.canRetry)

                ShareLink(item: model.diagnosticJSON(for: record),
                          preview: SharePreview("MixCapture diagnostic")) {
                    Label("مشاركة", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .font(.callout)

            if record.transcript != nil {
                HStack {
                    Button("سجّل كمصروف", systemImage: "creditcard") { showingExpense = true }
                    Button("أنشئ تذكير", systemImage: "bell.badge") { showingReminder = true }
                }
                .buttonStyle(.bordered)
                Picker("التقييم اليدوي", selection: Binding(
                    get: { record.assessment },
                    set: { model.setAssessment($0, for: record.id) }
                )) {
                    Text("لم يُقيّم").tag(ManualAssessment.unassessed)
                    Text("correct ✓").tag(ManualAssessment.correct)
                    Text("needs work").tag(ManualAssessment.needsWork)
                }
                .pickerStyle(.segmented)
            }

            if let history = record.transcriptHistory, !history.isEmpty {
                DisclosureGroup("نتائج سابقة محفوظة (\(history.count))") {
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
