import SwiftUI
import WingcordCore

/// The Get Started step this channel is, above the message box (Discord's
/// `575293`): "Send a message" while a *write* step waits, then — once it is
/// done — the next step, "Next: …  in #channel", which goes there.
struct GuideStepBanner: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        if let content {
            Button {
                if let next = content.next { model.selectChannel(next.channelID) }
            } label: {
                HStack(spacing: Spacing.snug) {
                    Image(systemName: content.next == nil ? content.symbol : "signpost.right.fill")
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(content.next == nil ? Ink.secondary : Palette.accent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(content.title)
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Text(content.subtitle)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: Spacing.snug)
                    if content.next != nil {
                        Image(systemName: "arrow.right")
                            .font(.system(.caption, weight: .bold))
                            .foregroundStyle(Ink.secondary)
                    } else if content.isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color(red: 0.14, green: 0.64, blue: 0.35))
                            .font(.system(size: 18))
                    }
                }
                .padding(.horizontal, Spacing.margin)
                .padding(.vertical, Spacing.snug)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Palette.edge, lineWidth: 1)
                )
                .contentShape(.rect(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(content.next == nil)
            .padding(.horizontal, Spacing.margin)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(motion.standard, value: content.isDone)
        }
    }

    private struct Content: Equatable {
        var title: String
        var subtitle: String
        var symbol: String
        var isDone: Bool
        var next: ServerGuide.Action?
    }

    /// Discord's rules: only for a new member who is not still pending, in a
    /// step's own channel; a *read* step shows nothing until it is done.
    private var content: Content? {
        guard let guildID = model.channelIndex.guildID(of: channelID),
              let steps = model.pendingGuideSteps(in: guildID),
              !model.isPendingMember(inGuild: guildID),
              let step = steps.first(where: { $0.channelID == channelID })
        else { return nil }
        let isDone = model.isGuideStepDone(step.channelID, in: guildID)
        if isDone {
            guard let next = steps.first(where: {
                $0.channelID != channelID && !model.isGuideStepDone($0.channelID, in: guildID)
            }) else { return nil }
            let channelName = model.channelIndex[next.channelID].map { "#" + model.displayName(of: $0) } ?? "another channel"
            return Content(title: "Next: \(next.title)", subtitle: "in \(channelName)", symbol: "", isDone: true, next: next)
        }
        guard step.kind == .write else { return nil }
        return Content(title: step.title, subtitle: "Send a message", symbol: "bubble.left.and.pencil", isDone: false, next: nil)
    }
}

/// Which server's Get Started the reader has just finished.
struct GuideFinishedRequest: Identifiable, Hashable {
    var id: GuildID
}

/// Discord's moment when the last step is done (`455796`): the bar filling,
/// and "You've explored N starter channels, great job!".
struct GuideFinishedSheet: View {
    var guildID: GuildID

    @Environment(AppModel.self) private var model
    @ModalDismiss private var dismiss
    @State private var filled = false

    var body: some View {
        let count = model.serverGuides[guildID]?.actions.count ?? 0
        FormSheet(
            title: "Get Started",
            subtitle: Text(model.guilds[guildID]?.name ?? ""),
            confirmTitle: "Done",
            canConfirm: true,
            width: 380,
            confirmSymbol: "checkmark",
            confirm: { dismiss() }
        ) {
            VStack(spacing: Spacing.margin) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(Color(red: 0.14, green: 0.64, blue: 0.35))
                    .symbolEffect(.bounce, value: filled)
                Text("You\u{2019}ve explored \(count) starter \(count == 1 ? "channel" : "channels"), great job!")
                    .font(.system(.title3, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Color(red: 0.35, green: 0.80, blue: 0.47), Color(red: 0.55, green: 0.88, blue: 0.62)],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: proxy.size.width * (filled ? 1 : (count > 0 ? Double(count - 1) / Double(count) : 0)))
                    }
                }
                .frame(height: 8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.snug)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.spring(duration: 0.6, bounce: 0.2)) { filled = true }
        }
    }
}

/// Presents `GuideFinishedSheet` when Discord says the guide is done.
struct GuideFinishedPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.modal(item: Binding(
            get: { model.guideFinished.map(GuideFinishedRequest.init(id:)) },
            set: { model.guideFinished = $0?.id }
        )) { request in
            GuideFinishedSheet(guildID: request.id)
        }
    }
}

