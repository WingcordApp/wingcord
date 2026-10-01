import SwiftUI
import WingcordCore

/// A reaction's emoji at a given size — moving, when it is an animated one and
/// the reader lets things move.
///
/// **Shared by the chip's flyout and the reactors list**, which draw the same
/// emoji at 48 and 24 points: Discord plays an animated one in both.
///
/// The still is the frame the moving one starts on and stays underneath until
/// the film has frames, then goes — `GuildRailTile`'s hand-off, for its
/// reason: two decodes of one picture at two sizes read as a doubled rim.
struct ReactionEmoji: View {
    var emoji: EmojiRef
    var side: CGFloat

    @Environment(\.motion) private var motion
    /// The reader's battery switch, which names emoji among what it stills.
    @State private var settings = AppSettings.shared
    @State private var isPlaying = false

    private var plays: Bool {
        emoji.isAnimated && settings.playsAnimatedContent && !motion.reduceMotion
    }

    var body: some View {
        InlineEmojiMark(emoji: emoji, side: side)
            .opacity(isPlaying ? 0 : 1)
            .overlay {
                if plays, let id = emoji.id, let url = CDN.emoji(id: id, animated: true, side: side) {
                    AnimatedDecoration(url: url, side: side, onPlayback: { playing in
                        guard isPlaying != playing else { return }
                        isPlaying = playing
                    })
                    .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
            // The film cannot report that it stopped once it has left the tree.
            .onChange(of: plays) { if !plays { isPlaying = false } }
            .accessibilityHidden(true)
    }
}
