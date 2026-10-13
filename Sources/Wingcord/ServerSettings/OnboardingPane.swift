import SwiftUI
import WingcordCore

// MARK: - Onboarding
//
// Discord's Onboarding home (`gY`): whether it is on, then three rows — Default
// Channels, Questions, Server Guide — each saying where it stands ("Good",
// "Warning", "Required") and opening its own editor. Every word is Discord's.
//
// **The numbers are Discord's tests**: a server needs at least one Default
// Channel new members can talk in (`Kd`), and Questions read "Good" once 85
// per cent of the public channels are reachable through them and the
// defaults. "Public" here is what `@everyone` can see — the channel summaries
// already know it.

struct OnboardingPane: View {
    let store: ServerSettingsStore

    @State private var page = Page.home

    enum Page: Hashable {
        case home
        case defaultChannels
        case questions
        case serverGuide
    }

    /// Discord's `Kd`: the Default Channels new members must be able to talk in.
    private static let requiredChattableChannels = 1

    var body: some View {
        LoadableContent(store.onboarding) { onboarding in
            switch page {
            case .home:
                home(onboarding)
            case .defaultChannels:
                subpage("Default Channels") {
                    OnboardingDefaultChannelsEditor(store: store, onboarding: onboarding)
                }
            case .questions:
                subpage("Questions") {
                    OnboardingQuestionsEditor(store: store, onboarding: onboarding)
                }
            case .serverGuide:
                subpage("Server Guide") {
                    LoadableContent(store.serverGuide) { guide in
                        GuideEditor(store: store, guide: guide)
                    }
                }
            }
        }
    }

    // MARK: Home

    private func home(_ onboarding: GuildOnboarding) -> some View {
        let chattable = chattableDefaults(onboarding)
        let isReady = chattable >= Self.requiredChattableChannels
        return VStack(alignment: .leading, spacing: 0) {
            enableCard(onboarding, isReady: isReady)
            SettingsGroup {
                SettingsCard {
                    defaultChannelsRow(onboarding, chattable: chattable, isReady: isReady)
                    CardDivider()
                    questionsRow(onboarding)
                    CardDivider()
                    serverGuideRow(isOnboardingEnabled: onboarding.isEnabled)
                }
            }
        }
    }

    @ViewBuilder
    private func enableCard(_ onboarding: GuildOnboarding, isReady: Bool) -> some View {
        SettingsGroup {
            SettingsCard {
                if onboarding.isEnabled {
                    DescribedRow("Onboarding is Enabled") {
                        Toggle("Onboarding is Enabled", isOn: Binding(
                            get: { true },
                            set: { isOn in Task { await store.setOnboardingEnabled(isOn) } }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(SettingsSurface.switchOn)
                    }
                } else {
                    DescribedRow(
                        isReady ? "You're ready to enable" : "You're missing a few items...",
                        detail: Text(isReady
                            ? "Push the big blue button to turn on your new member experience!"
                            : "To enable Onboarding, you must meet these requirements.")
                    ) {
                        Button("Enable Onboarding") {
                            Task { await store.setOnboardingEnabled(true) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!isReady)
                    }
                }
            }
            if !onboarding.isEnabled {
                SettingsFootnote("Once enabled, getting a role will not bypass a member through verification and Rules. To manually verify members, you can right click a user and select Verify Member, or use the Members tab.")
            }
        }
    }

    private func defaultChannelsRow(_ onboarding: GuildOnboarding, chattable: Int, isReady: Bool) -> some View {
        let count = onboarding.defaultChannelIDs.count
        let detail = isReady
            ? (count == 1 ? "You have 1 Default Channel" : "You have \(count) Default Channels")
            : (Self.requiredChattableChannels == 1
                ? "You must have 1 channel new members can talk in"
                : "You must have \(Self.requiredChattableChannels) channels new members can talk in")
        return OnboardingStepRow(
            title: "Default Channels",
            detail: detail,
            symbolName: "number",
            status: isReady ? .good : .required,
            hasStarted: count > 0
        ) { page = .defaultChannels }
    }

    private func questionsRow(_ onboarding: GuildOnboarding) -> some View {
        let publicIDs = Set(store.channels.filter(\.isPublic).map(\.id))
        var reachable = Set(onboarding.defaultChannelIDs)
        for prompt in onboarding.prompts {
            for option in prompt.options { reachable.formUnion(option.channelIDs) }
        }
        let assigned = publicIDs.intersection(reachable).count
        let total = publicIDs.count
        let hasQuestions = !onboarding.prompts.isEmpty
        let isCovered = total > 0 && Double(assigned) / Double(total) * 100 >= 85
        return OnboardingStepRow(
            title: "Questions",
            detail: "\(assigned) of \(total) public channels are assignable through Questions and Default Channels.",
            symbolName: "questionmark.bubble",
            status: hasQuestions ? (isCovered ? .good : .warning) : .none,
            hasStarted: hasQuestions
        ) { page = .questions }
    }

    @ViewBuilder
    private func serverGuideRow(isOnboardingEnabled: Bool) -> some View {
        let guide = store.serverGuide.value
        // Discord's test: a welcome message and at least three To Do tasks.
        let isComplete = guide.map { !($0.welcome?.message.isEmpty ?? true) && $0.actions.count >= 3 } ?? false
        let hasStarted = guide.map { !$0.isEmpty } ?? false
        let detail = isComplete
            ? (hasStarted
                ? "Your Welcome Message, Banner, To Do tasks, and Resources are all set up"
                : "Set up your Server Guide to help new members get started.")
            : "You must have a welcome message and at least 3 To Do tasks."
        OnboardingStepRow(
            title: "Server Guide",
            detail: detail,
            symbolName: "signpost.right.fill",
            status: hasStarted ? (isComplete ? .good : .required) : .none,
            hasStarted: hasStarted,
            accessory: {
                if let guide, hasStarted, isOnboardingEnabled {
                    Toggle("Server Guide", isOn: Binding(
                        get: { guide.isEnabled },
                        set: { isOn in Task { await store.saveServerGuide(guide, isEnabled: isOn) } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(SettingsSurface.switchOn)
                    .disabled(!isComplete)
                }
            }
        ) { page = .serverGuide }
    }

    /// The Default Channels `@everyone` can see — Discord's chattable set.
    private func chattableDefaults(_ onboarding: GuildOnboarding) -> Int {
        let publicIDs = Set(store.channels.filter(\.isPublic).map(\.id))
        return onboarding.defaultChannelIDs.filter(publicIDs.contains).count
    }

    // MARK: Sub-pages

    private func subpage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            Button { page = .home } label: {
                Label("Onboarding", systemImage: "chevron.left")
                    .font(SettingsType.controlLabel)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            Text(verbatim: title)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.primary)
            content()
        }
    }
}

/// One of Onboarding's rows (`gS`): its mark, title and sentence, where it
/// stands, and Edit — or Set up, before it has been started.
private struct OnboardingStepRow<Accessory: View>: View {
    var title: String
    var detail: String
    var symbolName: String
    var status: Status
    var hasStarted: Bool
    @ViewBuilder var accessory: () -> Accessory
    var edit: () -> Void

    enum Status {
        case none
        case good
        case warning
        case required
    }

    init(
        title: String,
        detail: String,
        symbolName: String,
        status: Status,
        hasStarted: Bool,
        @ViewBuilder accessory: @escaping () -> Accessory,
        edit: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.status = status
        self.hasStarted = hasStarted
        self.accessory = accessory
        self.edit = edit
    }

    var body: some View {
        DescribedRow(
            title,
            detail: Text(detail)
                .foregroundStyle(hasStarted && status == .required
                    ? AnyShapeStyle(Palette.destructive)
                    : AnyShapeStyle(Ink.secondary))
        ) {
            Image(symbol: symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 32, height: 32)
                .background(SettingsSurface.controlTrough, in: .circle)
                .accessibilityHidden(true)
        } trailing: {
            HStack(spacing: Spacing.snug) {
                badge
                accessory()
                Button(hasStarted ? "Edit" : "Set up", action: edit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch status {
        case .none:
            EmptyView()
        case .good:
            Label("Good", systemImage: "checkmark")
                .foregroundStyle(Palette.affirmative)
                .font(.system(.caption, weight: .semibold))
        case .warning:
            Label("Warning", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(.caption, weight: .semibold))
        case .required:
            Label("Required", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(Palette.destructive)
                .font(.system(.caption, weight: .semibold))
        }
    }
}

extension OnboardingStepRow where Accessory == EmptyView {
    init(
        title: String,
        detail: String,
        symbolName: String,
        status: Status,
        hasStarted: Bool,
        edit: @escaping () -> Void
    ) {
        self.init(
            title: title,
            detail: detail,
            symbolName: symbolName,
            status: status,
            hasStarted: hasStarted,
            accessory: { EmptyView() },
            edit: edit
        )
    }
}
