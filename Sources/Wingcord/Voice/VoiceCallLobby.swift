import SwiftUI

// MARK: - A call that is already happening, without you
//
// **The same panel, in the same place, before you are in it.** A conversation
// whose call you have left — or never joined — used to show nothing at all, and
// the only way back was a toolbar button that said "Start a Call" and rang the
// person still sitting in it.
//
// So the call does not disappear when you leave: it stays where it was, with
// the people still in it in the tiles they were already in, and joining is
// stepping back into a thing that is visibly still going. That is the whole
// idea, and it is why this is not a banner — a banner would be a *notice* about
// a call somewhere else, and the call is right here.
//
// Three things follow from it, and each is load-bearing:
//
// - **The same tiles.** `VoiceTileGrid`, the same faces, the same speaking
//   rings and mute badges, live. A watcher can see who is there and who is
//   talking before deciding, which is the question they actually have.
// - **The same glass, morphing.** This panel and `VoiceCallOverlay` share one
//   `glassEffectID`, so joining does not swap one surface for another: the
//   glass *is* the call panel, and it grows into it. §4, and the reason
//   `Motion.glassMorph` exists.
// - **No video.** Nothing is subscribed to anybody's camera until the reader
//   joins — see `AppModel.callLobby`. A lobby that decoded a stream would spend
//   a call's worth of CPU on a panel nobody has stepped into.
struct VoiceCallLobby: View {
    var participants: [VoiceParticipant]
    var join: () -> Void

    @Environment(\.motion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    /// Shorter than the call itself, and that is the point: this is the call
    /// waiting, not the call. Joining grows it, which is the motion that says
    /// what happened.
    static let height: CGFloat = 148

    var body: some View {
        VStack(spacing: 0) {
            VoiceTileGrid(
                participants: participants,
                spotlightUserID: nil,
                effects: [:],
                cameraSession: nil,
                selfUserID: nil,
                attachVideo: { _, _ in },
                spotlight: { _ in }
            )
            .padding(.horizontal, Spacing.snug)
            .padding(.top, Spacing.snug)
            .frame(maxHeight: .infinity)
            // The tiles are a picture of who is there; the button is the only
            // thing to press. Routing taps on them to the same act would make
            // the whole panel one enormous button with a decoy inside it.
            .allowsHitTesting(false)

            joinButton
                .padding(.vertical, Spacing.snug)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Layout first, glass last, and one body for the whole panel — §4.
        // `.clear`, never `.regular`: what passes under this is the transcript,
        // and frosting somebody's message into a grey slab is the one thing
        // glass exists not to do.
        .glassEffect(
            .clear.tint(Palette.flyoutTint),
            in: .rect(cornerRadius: Radius.card)
        )
    }

    private var joinButton: some View {
        Button(action: join) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "phone.fill")
                    .symbolRenderingMode(.hierarchical)
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, Spacing.group)
            .padding(.vertical, Spacing.base)
        }
        // **A pill, like every other call control.** The bar under a call is
        // capsules, the tile name badges are capsules, and Accept on an
        // incoming call is a capsule — a rounded rectangle here is the one
        // shape in the surface that belongs to a different vocabulary.
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        // The same green Accept wears. Joining a call already running is the
        // affirmative call action, and giving it a colour of its own would be
        // a second vocabulary for one meaning.
        .tint(Palette.affirmative)
        // The press feedback is the button style's own. What this adds is the
        // hover lift macOS expects and iOS has no use for — fast enough that
        // running the pointer past leaves no trail behind it.
        .scaleEffect(isHovering && !reduceMotion ? 1.03 : 1)
        .onHover { isHovering = $0 }
        .animation(motion.hover, value: isHovering)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(hint))
    }

    private var title: String {
        participants.count == 1 ? "Join \(participants[0].displayName)" : "Join the Call"
    }

    /// What VoiceOver is told, which is the thing a sighted reader gets from
    /// the tiles: who is in there.
    private var hint: String {
        let names = participants.map(\.displayName)
        return switch names.count {
        case 0: "Nobody is in this call."
        case 1: "\(names[0]) is in this call."
        case 2: "\(names[0]) and \(names[1]) are in this call."
        default: "\(names[0]), \(names[1]) and \(names.count - 2) others are in this call."
        }
    }
}
