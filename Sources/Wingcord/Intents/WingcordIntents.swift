import AppIntents
import WingcordCore

// MARK: - Actions for Shortcuts
//
// What Wingcord offers the Shortcuts app on a Mac — and through it Spotlight,
// Siri and a Shortcuts automation like "when Gaming Focus turns on". Each one
// is a task somebody asks for, not a button on a screen, and each calls the
// same model method the menu bar does, so a Shortcut and a click can never
// disagree about what an action means.
//
// They run in the app's own process: `App.init()` registers the model and
// `FocusSync` with `AppDependencyManager` before any of these can fire.
//
// **The shape every intent here keeps, under this target's default main-actor
// isolation**: a plain `struct`/`enum`, `nonisolated` on exactly the protocol's
// synchronous requirements (`title`, `description`, `parameterSummary`,
// `init()`, `displayRepresentation`, an enum's display tables) and
// `@MainActor func perform()`. A `nonisolated struct` does not compile — its
// `@Parameter` storage is a mutable stored property — and the metadata
// processor reads this shape whole (probe, 2026-10-20).

nonisolated enum WingcordIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notConnected
    case notInVoice
    case clipsOff

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConnected: "Wingcord isn't connected to Discord."
        case .notInVoice: "You aren't in a voice channel or call."
        case .clipsOff: "Clips is off. Turn it on in Wingcord's Settings › Clips."
        }
    }
}

// MARK: Status

enum StatusChoice: String, AppEnum {
    case online
    case idle
    case doNotDisturb
    case invisible

    nonisolated static let typeDisplayRepresentation: TypeDisplayRepresentation = "Status"
    nonisolated static let caseDisplayRepresentations: [StatusChoice: DisplayRepresentation] = [
        .online: "Online",
        .idle: "Idle",
        .doNotDisturb: "Do Not Disturb",
        .invisible: "Invisible",
    ]

    var presence: PresenceStatus {
        switch self {
        case .online: .online
        case .idle: .idle
        case .doNotDisturb: .doNotDisturb
        case .invisible: .invisible
        }
    }
}

struct SetStatusIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Set Status"
    nonisolated static let description = IntentDescription(
        "Sets your Discord status — Online, Idle, Do Not Disturb or Invisible.",
        categoryName: "Status"
    )

    @Parameter(title: "Status", default: .online)
    var status: StatusChoice

    @Dependency private var model: AppModel

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Set status to \(\.$status)")
    }

    nonisolated init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard model.connectionState == .ready else { throw WingcordIntentError.notConnected }
        model.updateSelfStatus(status.presence)
        return .result()
    }
}

enum ClearAfterChoice: String, AppEnum {
    case never
    case thirtyMinutes
    case oneHour
    case fourHours
    case today

    nonisolated static let typeDisplayRepresentation: TypeDisplayRepresentation = "Clear After"
    nonisolated static let caseDisplayRepresentations: [ClearAfterChoice: DisplayRepresentation] = [
        .never: "Don't clear",
        .thirtyMinutes: "30 minutes",
        .oneHour: "1 hour",
        .fourHours: "4 hours",
        .today: "24 hours",
    ]

    var duration: CustomStatusDuration {
        switch self {
        case .never: .never
        case .thirtyMinutes: .thirtyMinutes
        case .oneHour: .oneHour
        case .fourHours: .fourHours
        case .today: .today
        }
    }
}

struct SetCustomStatusIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Set Custom Status"
    nonisolated static let description = IntentDescription(
        "Sets the words and emoji under your name. Leave both empty to clear it.",
        categoryName: "Status"
    )

    @Parameter(title: "Text")
    var text: String?

    @Parameter(title: "Emoji", description: "One emoji, like 🎮.")
    var emoji: String?

    @Parameter(title: "Clear After", default: .never)
    var clearAfter: ClearAfterChoice

    @Dependency private var model: AppModel

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Set custom status to \(\.$text)") {
            \.$emoji
            \.$clearAfter
        }
    }

    nonisolated init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard model.connectionState == .ready else { throw WingcordIntentError.notConnected }
        let words = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let glyph = emoji?.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = CustomStatus(
            text: words.map { String($0.prefix(CustomStatus.textLimit)) },
            emoji: glyph.flatMap { $0.isEmpty ? nil : EmojiRef(name: String($0.prefix(16))) },
            expiresAt: clearAfter.duration.expiry()
        )
        model.updateSelfCustomStatus(status.isEmpty ? nil : status)
        return .result()
    }
}

// MARK: Voice

enum MicrophoneAction: String, AppEnum {
    case toggle
    case mute
    case unmute

    nonisolated static let typeDisplayRepresentation: TypeDisplayRepresentation = "Microphone"
    nonisolated static let caseDisplayRepresentations: [MicrophoneAction: DisplayRepresentation] = [
        .toggle: "Toggle mute",
        .mute: "Mute",
        .unmute: "Unmute",
    ]
}

struct SetMicrophoneIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Mute or Unmute"
    nonisolated static let description = IntentDescription("Mutes or unmutes your microphone in Wingcord.", categoryName: "Voice")

    @Parameter(title: "Action", default: .toggle)
    var action: MicrophoneAction

    @Dependency private var model: AppModel

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) the microphone")
    }

    nonisolated init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        switch action {
        case .toggle: model.toggleVoiceMute()
        case .mute: if !model.isSelfMuted { model.toggleVoiceMute() }
        case .unmute: if model.isSelfMuted { model.toggleVoiceMute() }
        }
        return .result()
    }
}

enum DeafenAction: String, AppEnum {
    case toggle
    case deafen
    case undeafen

    nonisolated static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sound"
    nonisolated static let caseDisplayRepresentations: [DeafenAction: DisplayRepresentation] = [
        .toggle: "Toggle deafen",
        .deafen: "Deafen",
        .undeafen: "Undeafen",
    ]
}

struct SetDeafenIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Deafen or Undeafen"
    nonisolated static let description = IntentDescription("Turns everyone's sound off or back on in Wingcord.", categoryName: "Voice")

    @Parameter(title: "Action", default: .toggle)
    var action: DeafenAction

    @Dependency private var model: AppModel

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action)")
    }

    nonisolated init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        switch action {
        case .toggle: model.toggleVoiceDeafen()
        case .deafen: if !model.isSelfDeafened { model.toggleVoiceDeafen() }
        case .undeafen: if model.isSelfDeafened { model.toggleVoiceDeafen() }
        }
        return .result()
    }
}

struct LeaveVoiceIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Leave Voice"
    nonisolated static let description = IntentDescription("Leaves the voice channel or call you are in.", categoryName: "Voice")

    @Dependency private var model: AppModel

    nonisolated init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard model.connectedVoiceChannelID != nil else { throw WingcordIntentError.notInVoice }
        model.leaveVoice()
        return .result()
    }
}

// MARK: Clips

struct SaveClipIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Save Clip"
    nonisolated static let description = IntentDescription(
        "Saves the last few seconds of the game you are playing.",
        categoryName: "Clips"
    )

    @Dependency private var model: AppModel

    nonisolated init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard AppSettings.shared.clipsEnabled else { throw WingcordIntentError.clipsOff }
        model.saveClip()
        return .result()
    }
}

struct TakeScreenshotIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Take Screenshot"
    nonisolated static let description = IntentDescription(
        "Saves the game's window — or the screen, with no game running — to the clips folder.",
        categoryName: "Clips"
    )

    @Dependency private var model: AppModel

    nonisolated init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        model.saveScreenshot()
        return .result()
    }
}

// MARK: Recording

struct StartRecordingIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Start Recording"
    nonisolated static let description = IntentDescription(
        "Records the screen, a window or an area — as the capture bar is set — with the camera, the microphone and the Mac's sound as the bar has them.",
        categoryName: "Clips"
    )

    @Dependency private var model: AppModel

    nonisolated init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !model.capture.isRecording else { return .result() }
        model.capture.toggleRecording()
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Stop Recording"
    nonisolated static let description = IntentDescription(
        "Stops the recording Wingcord is making and saves it to the clips folder.",
        categoryName: "Clips"
    )

    @Dependency private var model: AppModel

    nonisolated init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await model.capture.stopRecording()
        return .result()
    }
}

// MARK: - App Shortcuts

/// The ready-made ones: no setup, in Spotlight and Siri as soon as Wingcord is
/// installed. Every phrase names the app, which App Intents requires.
struct WingcordShortcuts: AppShortcutsProvider {
    // `AppIntents.` spelled out: this app has its own `AppShortcut`, the
    // keyboard-shortcut table in `Hotkey/AppShortcut.swift`.
    nonisolated static var appShortcuts: [AppIntents.AppShortcut] {
        AppIntents.AppShortcut(
            intent: SetStatusIntent(),
            phrases: [
                "Set my \(.applicationName) status",
                "Set my \(.applicationName) status to \(\.$status)",
            ],
            shortTitle: "Set Status",
            systemImageName: "circle.lefthalf.filled"
        )
        AppIntents.AppShortcut(
            intent: SetMicrophoneIntent(),
            phrases: ["Mute in \(.applicationName)", "Toggle mute in \(.applicationName)"],
            shortTitle: "Mute or Unmute",
            systemImageName: "mic.slash"
        )
        AppIntents.AppShortcut(
            intent: SetDeafenIntent(),
            phrases: ["Deafen in \(.applicationName)"],
            shortTitle: "Deafen or Undeafen",
            systemImageName: "speaker.slash"
        )
        AppIntents.AppShortcut(
            intent: LeaveVoiceIntent(),
            phrases: ["Leave voice in \(.applicationName)", "Hang up in \(.applicationName)"],
            shortTitle: "Leave Voice",
            systemImageName: "phone.down"
        )
        AppIntents.AppShortcut(
            intent: SaveClipIntent(),
            phrases: ["Save a clip with \(.applicationName)", "Clip that with \(.applicationName)"],
            shortTitle: "Save Clip",
            systemImageName: "film"
        )
        AppIntents.AppShortcut(
            intent: TakeScreenshotIntent(),
            phrases: ["Take a screenshot with \(.applicationName)"],
            shortTitle: "Take Screenshot",
            systemImageName: "camera.viewfinder"
        )
        AppIntents.AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start recording with \(.applicationName)", "Record my screen with \(.applicationName)"],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppIntents.AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop recording with \(.applicationName)"],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
    }
}
