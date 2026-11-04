import SwiftUI
import WingcordCore

/// The sheets a stage raises, one at a time.
enum StageSheet: Identifiable, Hashable {
    /// Discord's Start Stage — or Edit Stage, on a stage already live.
    case start
    /// Discord's Start Event, for a stage event about to begin.
    case startEvent(ScheduledEvent)
    /// "Welcome to Stages!", once ever.
    case welcome
    /// "Blocked Accounts Present", before joining a room with them in it.
    case blockedPresent

    var id: String {
        switch self {
        case .start: "start"
        case .startEvent(let event): "event-\(event.id)"
        case .welcome: "welcome"
        case .blockedPresent: "blocked"
        }
    }
}

/// Discord's picture over Start Stage and Welcome to Stages!, read from the
/// bundle once.
private enum StageArt {
    @MainActor static let image: NSImage? = Bundle.module
        .url(forResource: "start-stage", withExtension: "svg", subdirectory: "Art")
        .flatMap(NSImage.init(contentsOf:))
}

private struct StageArtwork: View {
    var body: some View {
        if let art = StageArt.image {
            Image(nsImage: art)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Start Stage

/// Discord's Start Stage dialog (chunk `8964a36b…`, module 95414), and the
/// same dialog as Edit Stage on a stage already live.
///
/// **It stays up until the stage is live** — INVARIANTS §1, "A page stays up
/// until the thing it raised has HAPPENED" — and a refusal is shown under the
/// topic in Discord's own words.
struct StartStageSheet: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var topic = ""
    @State private var notifyEveryone = false
    @State private var isWorking = false
    @State private var error: String?
    @State private var isPeopleOpen = false

    /// Discord's `RY`.
    private static let limit = 240

    var body: some View {
        let stage = model.stagePresentation(of: channelID)
        let isEditing = stage?.isLive == true
        FormSheet(
            title: isEditing ? "Edit Stage" : "What will you be talking about?",
            subtitle: Text(isEditing ? "Change the topic" : "Write a topic to start your Stage."),
            confirmTitle: isEditing ? "Save Changes" : "Start Stage",
            isWorking: isWorking,
            canConfirm: !trimmedTopic.isEmpty,
            confirm: submit
        ) {
            if !isEditing {
                StageArtwork()
                if let stage, stage.blockedCount + stage.ignoredCount > 0 {
                    flaggedNotice(stage)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Stage Topic")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                TextField("Stage Topic", text: $topic, prompt: Text("The debate is over: diet is better than regular"))
                    .modalField()
                    .onSubmit(submit)
                    .onChange(of: topic) { _, text in
                        if text.count > Self.limit { topic = String(text.prefix(Self.limit)) }
                    }
                if let error {
                    Text(error)
                        .font(.system(.caption))
                        .foregroundStyle(Palette.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let stage { StageAgeNotice(stage: stage) }
            if offersNotify(isEditing: isEditing) {
                Toggle("Notify @everyone", isOn: $notifyEveryone)
                    .toggleStyle(.checkbox)
            }
        }
        .onAppear {
            topic = model.stage(in: channelID)?.topic ?? ""
            // Discord's default: on for a server of fifty thousand or fewer,
            // where the ping is a notice rather than a flood.
            notifyEveryone = model.channelIndex[channelID]?.guildID
                .flatMap { model.guilds[$0]?.memberCount }
                .map { $0 <= 50_000 } ?? false
        }
    }

    private var trimmedTopic: String { topic.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Discord's `ts`: a new stage, by somebody who may ping everybody.
    private func offersNotify(isEditing: Bool) -> Bool {
        !isEditing && model.permissionGate.permissions(in: channelID).contains(.mentionEveryone)
    }

    /// Discord's notice when the room holds people the reader has blocked or
    /// ignored (module 918192, `Bw`), with View all.
    private func flaggedNotice(_ stage: StagePresentation) -> some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: stage.blockedCount > 0 ? "nosign" : "eye.slash")
                .foregroundStyle(stage.blockedCount > 0 ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.secondary))
            Text(StageFlaggedCopy.notice(blocked: stage.blockedCount, ignored: stage.ignoredCount))
                .font(.system(.caption))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("View all") { isPeopleOpen = true }
                .buttonStyle(.link)
                .font(.system(.caption))
                .popover(isPresented: $isPeopleOpen, arrowEdge: .trailing) {
                    StageFlaggedList(people: model.stageFlaggedPeople(in: channelID))
                        .padding(Spacing.snug)
                        .frame(width: 280)
                }
        }
    }

    private func submit() {
        let topic = trimmedTopic
        guard !isWorking, !topic.isEmpty else { return }
        error = nil
        isWorking = true
        Task {
            let refusal = if model.stage(in: channelID) != nil {
                await model.setStageTopic(topic, inChannel: channelID)
            } else {
                await model.startStage(
                    inChannel: channelID,
                    topic: topic,
                    notifyEveryone: offersNotify(isEditing: false) && notifyEveryone
                )
            }
            isWorking = false
            if let refusal { error = refusal } else { dismiss() }
        }
    }
}

/// Discord's Start Event for a stage event (module 914119): the event's name
/// as the title, "You are about to start this event" — Discord's hook for the
/// privacy level draws nothing for a private one, which every stage event now
/// is — and Notify @everyone, on, as Discord has it for a stage. Starting it
/// is starting the stage, with the event's name as the topic.
struct StageEventStartSheet: View {
    var event: ScheduledEvent
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var notifyEveryone = true
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        FormSheet(
            title: event.name,
            subtitle: Text("You are about to start this event"),
            confirmTitle: "Start Event",
            isWorking: isWorking,
            confirm: submit
        ) {
            if let description = event.description, !description.isEmpty {
                Text(description)
                    .font(.system(.body))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let stage = model.stagePresentation(of: channelID) { StageAgeNotice(stage: stage) }
            if let error {
                Text(error)
                    .font(.system(.caption))
                    .foregroundStyle(Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Notify @everyone", isOn: $notifyEveryone)
                .toggleStyle(.checkbox)
        }
    }

    private func submit() {
        guard !isWorking else { return }
        error = nil
        isWorking = true
        Task {
            let refusal = await model.startStage(
                inChannel: channelID, topic: event.name, notifyEveryone: notifyEveryone, event: event
            )
            isWorking = false
            if let refusal { error = refusal } else { dismiss() }
        }
    }
}

/// Discord's age notice in the stage's dialogs (module 660110): a teen is
/// told they cannot speak on a stage, and why; anybody else held back is told
/// what Discord asks of them.
struct StageAgeNotice: View {
    var stage: StagePresentation

    var body: some View {
        if stage.withholdsSpeaking {
            Label {
                Text(
                    stage.isTeen
                        ? "You are in the teen age group and cannot use the mic or camera in Stages. [Learn more](https://support.discord.com/hc/en-us/articles/30326565624343)"
                        : "You must confirm you\u{2019}re an adult to speak on Stages."
                )
                .font(.system(.caption))
                .foregroundStyle(Ink.primary)
                .tint(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: stage.isTeen ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(stage.isTeen ? Palette.accent : .orange)
            }
            .padding(Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.card, style: .continuous))
        }
    }
}

// MARK: - Blocked and ignored

/// Discord's sentences about the people a reader blocked or ignored being in
/// a stage (`P/KFXz`, `Ri3o33`, `6Tcdt7`, `28qZMU`, and the titles).
enum StageFlaggedCopy {
    static func notice(blocked: Int, ignored: Int) -> String {
        if blocked > 0, ignored > 0 {
            return "Just so you know, people you\u{2019}ve blocked or ignored are in this Stage."
        }
        if ignored > 0 {
            return "Just so you know, \(accounts(ignored, "ignored")) in this Stage."
        }
        return "\(accounts(blocked, "blocked")) in this Stage."
    }

    /// The join notice's line — Discord's own, which opens "Just so you know"
    /// for the blocked as well.
    static func joinNotice(blocked: Int, ignored: Int) -> String {
        if blocked > 0, ignored == 0 { return "Just so you know, \(accounts(blocked, "blocked")) in this Stage." }
        return notice(blocked: blocked, ignored: ignored)
    }

    static func title(blocked: Int, ignored: Int) -> String {
        if blocked > 0, ignored > 0 { return "Blocked and Ignored Accounts Present" }
        if ignored > 0 { return ignored == 1 ? "Ignored Account Present" : "Ignored Accounts Present" }
        return blocked == 1 ? "Blocked Account Present" : "Blocked Accounts Present"
    }

    private static func accounts(_ count: Int, _ verb: String) -> String {
        count == 1 ? "1 account you \(verb) is" : "\(count) accounts you \(verb) are"
    }
}

/// The people themselves, each with Blocked or Ignored and where they stand.
struct StageFlaggedList: View {
    var people: [StageFlaggedPerson]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            ForEach(people) { person in
                HStack(spacing: Spacing.base) {
                    AvatarView(url: person.avatarURL, monogram: person.monogram, side: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.name)
                            .font(.system(.subheadline))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        HStack(spacing: Spacing.tight) {
                            Text(person.isBlocked ? "Blocked" : "Ignored")
                                .foregroundStyle(person.isBlocked ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.secondary))
                            Text("| \(person.place)")
                                .foregroundStyle(Ink.tertiary)
                        }
                        .font(.system(.caption))
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Discord's notice before joining a stage with blocked or ignored people in
/// it (module 200629): who they are, Never mind, and Got it, thanks — which
/// joins.
struct StageBlockedSheet: View {
    var channelID: ChannelID
    var join: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let people = model.stageFlaggedPeople(in: channelID)
        let blocked = people.count { $0.isBlocked }
        let ignored = people.count - blocked
        FormSheet(
            title: StageFlaggedCopy.title(blocked: blocked, ignored: ignored),
            subtitle: Text(StageFlaggedCopy.joinNotice(blocked: blocked, ignored: ignored)),
            confirmTitle: "Got it, thanks",
            cancelTitle: "Never mind",
            closesOnConfirm: true,
            confirm: join
        ) {
            StageFlaggedList(people: people)
        }
    }
}

// MARK: - Welcome to Stages!

/// Discord's first-visit sheet (module 456947): what a stage is, in three
/// lines, and Got it!
struct StageWelcomeSheet: View {
    @ModalDismiss private var dismiss
    @Environment(\.isTopModal) private var isTop

    var body: some View {
        VStack(spacing: Spacing.margin) {
            StageArtwork()
            Text("Welcome to Stages!")
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(Ink.primary)
            VStack(alignment: .leading, spacing: Spacing.snug) {
                line("Your mic will be muted unless you are invited to speak.", symbol: "mic.slash.fill", tint: AnyShapeStyle(Palette.destructive))
                line("You can leave and rejoin anytime without making noise.", symbol: "door.left.hand.open", tint: AnyShapeStyle(Ink.secondary))
                line("Request to speak to join the conversation!", symbol: "hand.raised.fill", tint: AnyShapeStyle(Ink.secondary))
            }
            ModalButton(title: "Got it!", symbolName: "hand.thumbsup.fill", role: .act, fills: true) { dismiss() }
        }
        .padding(Spacing.group)
        .frame(width: 400)
        // Escape is Got it! too — the one way out answers both keys.
        .background {
            Button("", action: dismiss)
                .keyboardShortcut(isTop ? .cancelAction : nil)
                .hidden()
        }
    }

    private func line(_ text: String, symbol: String, tint: AnyShapeStyle) -> some View {
        HStack(spacing: Spacing.snug) {
            Image(systemName: symbol)
                .font(.system(.title2))
                .foregroundStyle(tint)
                .frame(width: 40)
            Text(text)
                .font(.system(.body))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
