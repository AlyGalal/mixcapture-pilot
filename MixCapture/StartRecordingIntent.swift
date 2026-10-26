import AppIntents

/// Foreground-only start for Back Tap / Shortcuts / Siri. Opening the app and recording in the
/// foreground is the deliberate pilot minimum (no AudioRecordingIntent, Live Activity or extension).
/// The request is queued in `CaptureModel` until the scene is active and the mic is allowed.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureModel.shared.requestStart()
        return .result()
    }
}

/// Back Tap can use this one action for both ends of a short capture.
struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Recording"
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureModel.shared.toggleRecording()
        return .result()
    }
}

/// Makes the intent discoverable in the Shortcuts app without user setup,
/// so it can be picked for Settings › Accessibility › Touch › Back Tap.
struct MixCaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Record with \(.applicationName)",
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.circle.fill"
        )
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: ["Toggle recording in \(.applicationName)"],
            shortTitle: "Toggle Recording",
            systemImageName: "record.circle"
        )
    }
}
