import SwiftUI
import WingcordCore

/// What the composer's `+` offers in one conversation, and what each row does.
///
/// **Nil hides a row** rather than disabling it — `INVARIANTS.md` §5.5 — and a
/// value with every row nil hides the `+` itself, as Discord's
/// `ChannelAttachButton` returns nothing for an empty list. Closures rather
/// than a model so the composer keeps reaching for nothing observable.
struct ComposerAttachActions {
    var uploadFile: (() -> Void)?
    var selectPhotos: (() -> Void)?
    /// Discord's Create Thread — New Thread beside the channel.
    var createThread: (() -> Void)?
    var createPoll: (() -> Void)?
    var useApps: (() -> Void)?
    /// "Invite #general to Listen to Spotify", while the reader's Spotify is
    /// on their status.
    var listenAlong: Invitation?
    /// Puts the composer into scheduling at the time picked.
    var schedule: ((Date) -> Void)?

    struct Invitation {
        var title: String
        var send: () -> Void
    }

    var isEmpty: Bool {
        uploadFile == nil && selectPhotos == nil && createThread == nil && createPoll == nil && useApps == nil
            && listenAlong == nil && schedule == nil
    }
}

/// The `+` menu — Discord's `channel-attach`, in its order: files, a thread,
/// a poll, apps, an invitation to what the reader is listening to, and a time
/// to send at.
///
/// **One surface that swaps its contents**, as `ServerOptionsMenu` does:
/// Schedule Message leads to Discord's suggested times, and Custom… to the time
/// picker, inside the same popover rather than a second one hung off a row.
/// Nothing is painted but row highlights — §4.9.
struct ComposerAttachMenu: View {
    var actions: ComposerAttachActions
    var close: () -> Void

    @Environment(\.motion) private var motion
    @State private var surface = Surface.root

    private enum Surface: Hashable {
        case root
        case schedule
        case customTime
    }

    static let width: CGFloat = 248

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch surface {
            case .root: root
            case .schedule: presets
            case .customTime: customTime
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: Self.width)
        .animation(motion.standard, value: surface)
    }

    @ViewBuilder
    private var root: some View {
        if let uploadFile = actions.uploadFile {
            FlyoutRow(title: "Upload a File", symbolName: "arrow.up.document") { run(uploadFile) }
        }
        if let selectPhotos = actions.selectPhotos {
            FlyoutRow(title: "Select from Photos", symbolName: "photo.on.rectangle.angled") { run(selectPhotos) }
        }
        if let createThread = actions.createThread {
            FlyoutRow(title: "Create Thread", symbolName: DiscordGlyph.newThread) { run(createThread) }
        }
        if let createPoll = actions.createPoll {
            FlyoutRow(title: "Create Poll", symbolName: "chart.bar.horizontal.page") { run(createPoll) }
        }
        if let useApps = actions.useApps {
            FlyoutRow(title: "Use Apps", symbolName: "circle.grid.2x2.fill") { run(useApps) }
        }
        if let listenAlong = actions.listenAlong {
            FlyoutRow(title: listenAlong.title, symbolName: "headphones") { run(listenAlong.send) }
        }
        if actions.schedule != nil {
            FlyoutRow(title: "Schedule Message", symbolName: "clock", accessory: .disclosure) {
                surface = .schedule
            }
        }
    }

    /// Discord's three suggestions, read off the clock as the list opens, and
    /// Custom… under a rule.
    @ViewBuilder
    private var presets: some View {
        FlyoutBackRow(title: "Schedule Message") { surface = .root }
        FlyoutDivider()
        ForEach(ScheduleWindow.presets(at: .now)) { preset in
            FlyoutRow(title: preset.title) { pick(preset.date) }
        }
        FlyoutDivider()
        FlyoutRow(title: "Custom...") { surface = .customTime }
    }

    @ViewBuilder
    private var customTime: some View {
        FlyoutBackRow(title: "Schedule Message") { surface = .schedule }
        ScheduleTimeForm(
            initial: ScheduleWindow.suggestedTime(at: .now),
            cancel: close,
            set: pick
        )
    }

    private func pick(_ date: Date) {
        close()
        actions.schedule?(date)
    }

    private func run(_ action: () -> Void) {
        close()
        action()
    }
}
