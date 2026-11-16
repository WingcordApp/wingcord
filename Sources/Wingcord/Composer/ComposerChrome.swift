import SwiftUI

/// The composer's two arrangements, and the only place that knows there are two.
///
/// **A silhouette is an arrangement.** `ChromeShape.enclosesFlankingControls`
/// states the rule; this view is where it lands. A boxy bar is one panel holding
/// everything — `+`, the field, the controls, a hairline and the send arrow —
/// because a rounded rectangle has flat sides and corners to spare. A pill is
/// three objects, because a circle enclosed in a capsule's rounded end collides
/// with it.
///
/// **It takes finished views, not descriptions of them.** Each control decides
/// its own material from the same shape — a glass body beside the plate, or a
/// region cut into it — so the rule lives once on `ChromeShape` and the chrome
/// here does nothing but place things. The alternative, a container that applies
/// glass to whatever it is handed, cannot let the send control carry an accent
/// tint without also inventing a vocabulary for saying so.
///
/// Both arrangements are `alignment: .bottom`, so a composer grown to three
/// lines keeps its controls on the last one rather than centring them against a
/// paragraph.
///
/// **What the message is and what it carries live inside the same glass**
/// (Alex, 2026-11-16, screenshots 29–31): a reply's or an edit's header and the
/// staged files stack over the words, hairlines between, and the plate grows
/// upward to hold them — one shape, never a strip floating over a pill.
struct ComposerChrome<Leading: View, Input: View, Controls: View, Send: View, Strip: View, Accessories: View>: View {
    var shape: ChromeShape
    @ViewBuilder var leading: Leading
    @ViewBuilder var input: Input
    @ViewBuilder var controls: Controls
    @ViewBuilder var send: Send
    /// A voice message's waveform: behind the field and the controls, the width of both.
    @ViewBuilder var strip: Strip
    /// The header and the tray, over the words. See `ComposerSection`.
    @ViewBuilder var accessories: Accessories

    /// The plate's corner.
    ///
    /// **Derived from the bar's resting height, not measured.** The bar grows
    /// with a wrapped message and a capsule's radius is half its height — but a
    /// radius that tracked the *grown* height would round a three-line composer
    /// into a lozenge. The resting height is the shape, and the plate keeps it
    /// as it grows, which is what every capsule text field on this platform
    /// does.
    private var corner: CGFloat {
        shape.cornerRadius(forHeight: Metrics.composerControlHeight)
    }

    var body: some View {
        if shape.enclosesFlankingControls {
            VStack(spacing: 0) {
                accessories
                HStack(alignment: .bottom, spacing: Spacing.hair) {
                    leading
                    HStack(alignment: .bottom, spacing: Spacing.hair) {
                        input
                        controls
                    }
                    .background(alignment: .bottom) { strip }
                    ComposerSendDivider()
                    send
                }
                .padding(.horizontal, Metrics.composerControlInset)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: corner))
        } else {
            HStack(alignment: .bottom, spacing: Spacing.base) {
                leading
                VStack(spacing: 0) {
                    accessories
                    HStack(alignment: .bottom, spacing: Spacing.hair) {
                        input
                        controls
                    }
                    .background(alignment: .bottom) { strip }
                    // The field's own inset. The trailing side is the last control's
                    // air, so both of its sides match.
                    .padding(.leading, Spacing.snug)
                    .padding(.trailing, Metrics.composerControlInset)
                }
                .glassEffect(.regular, in: .rect(cornerRadius: corner))
                send
            }
        }
    }
}

/// The hairline between the controls and the send arrow, inside a boxy bar.
///
/// **Only the enclosed arrangement has one**, and that is the whole reason it
/// exists: in a pill the send control is a separate body with real space around
/// it, so it is already separated. Enclosed, the arrow would otherwise be a
/// fifth control in a row of four, and the one that *commits* has to read apart
/// from the four that merely open a picker.
private struct ComposerSendDivider: View {
    var body: some View {
        Capsule()
            .fill(Ink.quaternary)
            .frame(width: 1, height: 16)
            .frame(width: Spacing.base, height: Metrics.composerControlHeight)
            .accessibilityHidden(true)
    }
}

/// Messages' arrangement (REDESIGN.md R7): `+` a glass circle of its own, then
/// one capsule holding the words and, at its trailing end, the emoji control
/// and the send arrow.
///
/// **The capsule keeps its resting corner as it grows**, for `ComposerChrome`'s
/// reason: a radius that tracked a three-line field would round it into a
/// lozenge. Bottom-aligned, so a grown field keeps its controls on the last
/// line.
struct MessagesComposerChrome<Leading: View, Input: View, Trailing: View, Strip: View, Accessories: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var input: Input
    @ViewBuilder var trailing: Trailing
    /// A voice message's waveform: behind the words and the controls, the width of both.
    @ViewBuilder var strip: Strip
    /// The header and the tray, over the words, inside the capsule — which
    /// keeps its corner as it grows, so it opens into a rounded panel.
    @ViewBuilder var accessories: Accessories

    var body: some View {
        HStack(alignment: .bottom, spacing: Spacing.base) {
            leading
            VStack(spacing: 0) {
                accessories
                HStack(alignment: .bottom, spacing: Spacing.hair) {
                    input
                    trailing
                }
                .background(alignment: .bottom) { strip }
                // The words start a capsule's corner in; the send disc sits as far
                // from the end as from the top and bottom.
                .padding(.leading, Metrics.composerTextInset)
                .padding(.trailing, MessagesSendButton.inset)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: Metrics.composerControlHeight / 2))
        }
    }
}
