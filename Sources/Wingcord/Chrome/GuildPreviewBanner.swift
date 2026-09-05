import SwiftUI
import WingcordCore

/// The strip across the top of a server the reader is only looking at.
///
/// **It is chrome, not content, and that is why it is a `safeAreaBar`.** Placed
/// as an overlay it would cover the first row of the transcript; placed as a
/// sibling above it, the transcript would stop short and the scroll-edge blur
/// would key off the wrong edge. A bar registers with the safe area, so the
/// canvas underneath keeps running to the window's top and simply pays for it as
/// a content inset — the same arrangement the composer already uses at the foot.
///
/// **One sentence, one verb, one way out.** The reader is here by accident of a
/// link and needs to know two things: that they cannot talk, and how to change
/// that. Everything else — the server's name, its icon, its member count — is
/// already on screen underneath.
struct GuildPreviewBanner: View {
    var preview: GuildPreviewPresentation
    var join: () -> Void
    var leave: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: Spacing.base) {
            Button(action: leave) {
                Label("Back", systemImage: "chevron.backward")
                    .font(.system(.subheadline, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(InkColor.primary)
            .interactiveChromeOverMedia(in: .capsule)

            Spacer(minLength: Spacing.base)

            Text("You are only looking around. Join to start chatting.")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                // The message is the reason the bar exists, so it is what gives
                // when the window narrows — the two controls are fixed-size and
                // both of them are verbs.
                .layoutPriority(-1)

            Spacer(minLength: Spacing.base)

            Button(action: join) {
                HStack(spacing: 6) {
                    if preview.isJoining {
                        ProgressView().controlSize(.mini)
                    }
                    Text(preview.isJoining ? "Joining…" : "Join \(preview.guildName)")
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 28)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(InkColor.primary)
            .interactiveChromeOverMedia(in: .capsule)
            .disabled(preview.isJoining)
            .accessibilityLabel(Text("Join \(preview.guildName)"))
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        // **A tint over the material, not a filled bar.** The window's ground is
        // the wallpaper coming through vibrancy; a solid accent strip across it
        // is the one thing in this app that would stop the desktop dead. The
        // hue is the reader's own accent, at the strength `INVARIANTS.md` §4
        // gives a chrome wash.
        .background {
            Rectangle()
                .fill(Palette.accent.opacity(0.22))
                .background(.regularMaterial)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        // Enters and leaves along the edge it lives on — §3's spatial symmetry.
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(motion.reposition, value: preview.isJoining)
        .accessibilityElement(children: .contain)
    }
}

/// What stands in for the composer while previewing.
///
/// **The same slab, the same glass and the same height as the composer**, for
/// the reason `PermissionNotice` already gives: the foot of the transcript must
/// not change height as the reader moves between a channel they can post in and
/// one they cannot. What differs is that this one has somewhere to go — it is
/// the way back to the page that sent them here, which is the only navigation a
/// previewed server offers.
struct PreviewReturnBar: View {
    var preview: GuildPreviewPresentation
    var back: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            mark
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Spacing.base)
            Button(action: back) {
                Label("Back to Profile", systemImage: "arrow.backward")
                    .font(.system(.subheadline, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 14)
                    .frame(height: Metrics.control)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(InkColor.primary)
            .interactiveChromeOverMedia(in: .capsule)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, 7)
        .frame(minHeight: Metrics.composerControlHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        guard let name = preview.returnTitle else { return "Back to where you came from" }
        return "Return to the \(name) game profile"
    }

    /// The game's square mark.
    ///
    /// **`Color.clear` under it**, because an aspect-filled picture reports the
    /// size it grew to and this bar is inside a `safeAreaBar` whose height the
    /// transcript pays for as an inset — see `AmbientArtwork` for what that
    /// costs when it is missed.
    @ViewBuilder
    private var mark: some View {
        if let url = preview.returnIconURL {
            Color.clear
                .frame(width: Metrics.previewReturnIcon, height: Metrics.previewReturnIcon)
                .overlay {
                    RemoteImage(url: url, side: Metrics.previewReturnIcon, bucket: .thumbnail) {
                        Rectangle().fill(Palette.surfaceRaised)
                    }
                    .aspectRatio(contentMode: .fill)
                }
                .clipShape(.circle)
                .accessibilityHidden(true)
        }
    }
}
