import SwiftUI
import WingcordCore

/// Who is in a call the reader isn't in: their faces, overlapping, at the Join
/// button's height, each ringed green while they talk.
///
/// **A gap punched between neighbours, not a ring drawn on top**: a stroke on a
/// stack of faces reads as so many outlined circles; a cut-out reads as depth,
/// and works on the frosted ground whatever shows through it.
struct CallLobbyFaces: View {
    var participants: [VoiceParticipant]

    static let side: CGFloat = 36
    /// How far each face tucks under the one before it.
    private static let overlap: CGFloat = 10
    /// The most faces drawn before "+N".
    private static let shownLimit = 4

    @Environment(\.motion) private var motion

    var body: some View {
        let shown = Array(participants.prefix(Self.shownLimit))
        let extra = participants.count - shown.count
        HStack(spacing: -Self.overlap) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, participant in
                face(participant)
                    // Each face is cut where the next one sits on it.
                    .mask {
                        ZStack(alignment: .trailing) {
                            Rectangle()
                            if index < shown.count - 1 || extra > 0 {
                                Circle()
                                    .frame(width: Self.side + 4, height: Self.side + 4)
                                    .offset(x: Self.side - Self.overlap + 2)
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                    }
                    .zIndex(Double(shown.count - index))
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .frame(width: Self.side, height: Self.side)
                    .background { Circle().fill(Palette.selectionFill) }
            }
        }
        .animation(motion.standard, value: participants.map(\.isSpeaking))
        .accessibilityHidden(true)
    }

    private func face(_ participant: VoiceParticipant) -> some View {
        AvatarView(url: participant.avatarURL, monogram: participant.monogram, side: Self.side)
            .overlay {
                Circle()
                    .strokeBorder(Palette.presenceOnline, lineWidth: 2)
                    .opacity(participant.isSpeaking ? 1 : 0)
            }
    }
}
