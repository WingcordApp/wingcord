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

    /// A press on the words, which the glass cannot hear itself
    /// (`ComposerPress`).
    @State private var press = ComposerPress()

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
                    send
                }
                .padding(.horizontal, Metrics.composerControlInset)
                // **Taller, with air above and below the row** (Alex,
                // 2026-11-18: "make it taller"), so the box reads as a box
                // rather than a pill with square corners.
                .padding(.vertical, composerBoxyBreath)
            }
            .background { ComposerPressProbe(press: press) }
            .background { ComposerPressLight(press: press, cornerRadius: corner) }
            // **Interactive glass**: the plate lights up under the press, as a
            // field in an iOS sheet does (Alex, 2026-11-17) — on its rim by
            // itself, on its words through `ComposerPress`.
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: corner))
            .modifier(ComposerPressResponse(press: press, cornerRadius: corner))
        } else {
            // One glass group, so `+`, the plate and the send body are one
            // layer that melts together when they come close, as `MessagesComposerChrome`'s do.
            GlassEffectContainer(spacing: Spacing.base) {
                HStack(alignment: .bottom, spacing: Spacing.base) {
                    leading
                    // The plate's own glass — a staged file's buttons, the
                    // record disc — is a group of its own, or the outer group
                    // would melt it into the plate it sits on.
                    GlassEffectContainer(spacing: 0) {
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
                    }
                    .background { ComposerPressProbe(press: press) }
                    .background { ComposerPressLight(press: press, cornerRadius: corner) }
                    // Interactive: lights up under the press, as an iOS sheet's
                    // field does (Alex, 2026-11-17) — on its rim by itself, on its
                    // words through `ComposerPress`.
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: corner))
                    .modifier(ComposerPressResponse(press: press, cornerRadius: corner))
                    send
                }
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
/// The boxy plate's air above and below its row.
private let composerBoxyBreath: CGFloat = 6

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

    /// A press on the words, which the glass cannot hear itself
    /// (`ComposerPress`).
    @State private var press = ComposerPress()

    var body: some View {
        // **One glass group: `+` and the capsule are one layer** (Alex,
        // 2026-11-18: "i dont think the composer and the "+" sit in the same
        // layer"). Messages' are: held and pulled toward each other, the two
        // bodies melt together, which only glass in one container does. The
        // spacing is the gap they rest at, so at rest they are two shapes and
        // only a press or a pull closes it.
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(alignment: .bottom, spacing: Spacing.base) {
                leading
                // The capsule's own glass — a staged file's buttons, the record
                // disc — is a group of its own, or the outer group would melt
                // it into the capsule it sits on.
                GlassEffectContainer(spacing: 0) {
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
                }
                .background { ComposerPressProbe(press: press) }
                .background {
                    ComposerPressLight(press: press, cornerRadius: Metrics.composerControlHeight / 2)
                }
                // **Interactive**, as the other arrangement's plate is (Alex,
                // 2026-11-18: "im clicking and it doesnt bulge") — on its rim by
                // itself, on its words through `ComposerPress`.
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Metrics.composerControlHeight / 2))
                .modifier(ComposerPressResponse(press: press, cornerRadius: Metrics.composerControlHeight / 2))
            }
        }
    }
}
