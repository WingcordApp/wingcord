import SwiftUI
import WingcordCore

/// The settings window.
///
/// A source list plus a detail pane, in the `Settings` scene — so ⌘, works, the
/// window is managed and restored by the system, and it can be left open beside
/// the thing being configured. Not a sheet over the main window: settings are
/// not modal to a conversation.
///
/// **The detail is one view type**, for the same reason the workspace's is:
/// swapping structurally different views into a split view's detail makes macOS
/// re-resolve the column widths on every selection.
struct SettingsView: View {
    @State private var section: SettingsSection = .appearance

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { entry in
                Label(entry.title, systemImage: entry.symbolName)
                    .tag(entry)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            SettingsDetail(section: section)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case appearance
    case chat
    case notifications
    case accounts
    case performance
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .chat: "Chat"
        case .notifications: "Notifications"
        case .accounts: "Accounts"
        case .performance: "Performance"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .appearance: "paintpalette"
        case .chat: "bubble.left.and.text.bubble.right"
        case .notifications: "bell.badge"
        case .accounts: "person.crop.circle"
        case .performance: "speedometer"
        case .about: "info.circle"
        }
    }
}

/// One view type, branching internally.
private struct SettingsDetail: View {
    var section: SettingsSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.group) {
                switch section {
                case .appearance: AppearanceSettings()
                case .chat: ChatSettings()
                case .notifications: NotificationSettings()
                case .accounts: AccountSettings()
                case .performance: PerformanceSettings()
                case .about: AboutSettings()
                }
            }
            .padding(Spacing.group)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .softScrollEdgesVertical()
        .navigationTitle(section.title)
    }
}

// MARK: - Sections

private struct AppearanceSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsGroup("Text") {
            HStack(spacing: Spacing.snug) {
                Text("Message size")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                Slider(value: $settings.textScale, in: 0.8...1.6, step: 0.05)
                    .frame(width: 200)
                Text(settings.textScale, format: .percent.precision(.fractionLength(0)))
                    .font(.system(.caption).monospacedDigit())
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            Text("Scales on top of the system text size, so the accessibility setting still applies.")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
        }

        SettingsGroup("Layout") {
            Toggle("Compact messages", isOn: $settings.isCompactMode)
            Toggle("Show member list by default", isOn: $settings.showsMemberListByDefault)
        }

        SettingsGroup("Motion") {
            Text("Wingcord follows Reduce Motion and Reduce Transparency from System Settings ▸ Accessibility ▸ Display.")
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
            // Deliberately NOT duplicated as an app toggle. Two switches for one
            // behaviour means a user who set the system one and still sees
            // animation cannot tell which is being honoured — and honouring only
            // the app's is exactly how someone who set Reduce Motion in System
            // Settings gets the full animation set anyway.
            Button("Open Accessibility Settings") {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}

private struct ChatSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        SettingsGroup("Messages") {
            Toggle("Show link previews", isOn: $settings.showsEmbeds)
            Toggle("Load images automatically", isOn: $settings.loadsImagesAutomatically)
            Toggle("Play animated emoji and avatars", isOn: $settings.playsAnimatedContent)
            Text("Turning animation off saves real power on battery: an animated emoji is a decode loop for as long as it is on screen.")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
        }

        SettingsGroup("Timestamps") {
            Toggle("Use 24-hour time", isOn: $settings.uses24HourTime)
        }
    }
}

private struct NotificationSettings: View {
    var body: some View {
        SettingsGroup("Notifications") {
            Text("Not built yet.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
        }
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @State private var accounts: [StoredAccount] = []

    var body: some View {
        SettingsGroup("Signed in") {
            if let userID = model.currentUserID, let user = model.users[userID] {
                HStack(spacing: Spacing.snug) {
                    AvatarView(
                        url: model.avatarURL(for: user, side: 40),
                        monogram: user.monogram,
                        side: 40
                    )
                    VStack(alignment: .leading, spacing: 0) {
                        Text(user.preferredName)
                            .font(.system(.body, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                        Text(user.handle)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                    }
                    Spacer(minLength: Spacing.base)
                    Button("Sign Out", role: .destructive) { model.signOut() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            } else {
                Text("Not signed in.")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
            }
        }

        SettingsGroup("Other accounts") {
            let others = accounts.filter { $0.id != model.currentUserID?.description }
            if others.isEmpty {
                Text("No other accounts stored on this Mac.")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
            }
            ForEach(others) { account in
                HStack(spacing: Spacing.snug) {
                    Text(account.preferredName)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.primary)
                    Spacer(minLength: Spacing.base)
                    Button("Switch") { model.resumeSession(for: account) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Button("Forget", role: .destructive) {
                        AccountLedger.remove(account.id)
                        accounts = AccountLedger.accounts()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.tertiary)
                    .controlSize(.small)
                }
            }
        }

        SettingsGroup("Credentials") {
            Text("Tokens are stored in the macOS Keychain, marked so they never sync to iCloud and are unreadable while the Mac is locked.")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
        }
        .task { accounts = AccountLedger.accounts() }
    }
}

private struct PerformanceSettings: View {
    @State private var settings = AppSettings.shared
    @State private var snapshot = PerformanceSnapshot.empty

    var body: some View {
        SettingsGroup("Inspector") {
            Toggle("Show performance inspector", isOn: $settings.showsPerformanceInspector)
            Text("A live overlay: frame time, memory footprint, cache occupancy and what each surface is holding. It costs nothing while it is off.")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
        }

        SettingsGroup("Now") {
            MetricRow("Memory footprint", value: snapshot.footprintDescription)
            MetricRow("Image cache budget", value: snapshot.imageBudgetDescription)
            MetricRow("Loaded transcripts", value: "\(snapshot.residentChannels)")
            MetricRow("Messages held", value: "\(snapshot.residentMessages)")
            MetricRow("Slow frames (last 300)", value: "\(snapshot.slowFrames)")
        }

        SettingsGroup("Maintenance") {
            Button("Free cached images") {
                ImageStore.shared.purge()
                snapshot = PerformanceMonitor.shared.snapshot()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            Text("Images come back from the on-disk cache, so this frees memory without costing a download.")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
        }
        // Sampling runs only while this pane is on screen. `.task` cancels on
        // disappear, which is the whole reason it is used rather than a timer —
        // a settings pane nobody is looking at must not sample memory once a
        // second for the life of the process.
        .task {
            while !Task.isCancelled {
                snapshot = PerformanceMonitor.shared.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        SettingsGroup("Wingcord") {
            Text("A native macOS Discord client.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
            MetricRow("Version", value: Bundle.main.shortVersion)
            MetricRow("Build", value: Bundle.main.buildVersion)
        }

        SettingsGroup("Notice") {
            Text("Wingcord is not affiliated with Discord. Using a third-party client is against Discord's terms of service; use it knowing that.")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
        }
    }
}

// MARK: - Pieces

private struct SettingsGroup<Content: View>: View {
    var title: String
    /// The BUILT view, not the builder closure. Storing an escaping
    /// `@ViewBuilder` keeps a closure per instance and stops SwiftUI seeing the
    /// content as structurally stable across updates.
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text(title.uppercased())
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.tertiary)
            VStack(alignment: .leading, spacing: Spacing.snug) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.margin)
            .background(Palette.surface, in: .rect(cornerRadius: Radius.glass))
        }
        .frame(maxWidth: 580, alignment: .leading)
    }
}

private struct MetricRow: View {
    var label: String
    var value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
            Spacer(minLength: Spacing.base)
            Text(value)
                .font(.system(.subheadline).monospacedDigit())
                .foregroundStyle(Ink.primary)
        }
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var buildVersion: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
