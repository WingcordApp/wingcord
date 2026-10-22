import SwiftUI
import WingcordCore

// MARK: - Activity, over the game
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D20). What the reader is showing as their
// activity right now — drawn with the card everybody else sees, from the list
// the presence write itself sends (`publishedEntries`), so it cannot disagree
// with what went out — and the two switches somebody reaches for mid-game:
// Share my activity, and Streamer Mode. Game Mode's state rides in the
// header, because it is about this game too.
//
// **A reading surface, so an opaque one** — the chat widget's rule: words over
// a moving game want a ground that does not move.

struct OverlayActivityWidget: View {
    @Bindable var controller: OverlayController
    @Environment(AppModel.self) private var model
    @State private var streamer = StreamerMode.shared
    @State private var gameMode = GameMode.shared

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            header
            let entries = model.publishedEntries
            if let entry = entries.first {
                CurrentActivityCard(
                    activity: Activity(published: entry.activity, sessionID: nil),
                    buttonURLs: entry.activity.buttonURLs,
                    ground: .neutral,
                    openGame: nil,
                    applicationIconURL: model.applicationIconURL(entry.activity.applicationID, side: 68),
                    platesItself: false,
                    isOwn: true
                )
                if entries.count > 1 {
                    Text(entries.count == 2 ? "And 1 more" : "And \(entries.count - 1) more")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                }
            } else {
                Text("Nothing is shared right now.")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.secondary)
            }
            Divider().opacity(0.5)
            switches
        }
        .padding(Spacing.snug)
        .frame(width: Self.width, alignment: .leading)
        .background(Palette.canvas, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.relative(dark: 0.10, light: 0.10), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
    }

    private var header: some View {
        HStack(spacing: Spacing.tight) {
            Text("ACTIVITY")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Ink.secondary)
            Spacer(minLength: 0)
            if gameMode.isActive {
                Label("Game Mode", systemImage: "leaf.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.presenceOnline)
                    .help(GameMode.overrideNote)
            }
            if streamer.isEnabled {
                Label("Streamer Mode", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9146FF))
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private var switches: some View {
        VStack(spacing: Spacing.tight) {
            toggle(
                "Share my activity",
                isOn: Binding(
                    get: { model.activityPrivacy.sharesCurrentGame },
                    set: { model.setSharesCurrentGame($0) }
                )
            )
            toggle(
                "Streamer Mode",
                isOn: Binding(get: { streamer.isEnabled }, set: { streamer.setEnabled($0) })
            )
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}
