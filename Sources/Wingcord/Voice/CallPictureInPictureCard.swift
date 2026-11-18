import SwiftUI
import WingcordCore

/// A call's stream or camera, small, over the window while the reader reads
/// something else: Discord's call PiP. The picture is the call's own (the
/// same sink a tile would hold); on hover, Return, Mute, Stop Watching for a
/// stream, and Leave.
struct CallPictureInPictureCard: View {
    var content: CallPictureInPictureContent

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            VoiceVideoView(userID: content.userID, attach: model.attachVideo, reportPixels: model.reportVideoPixels)
            if isHovering { controls.transition(.opacity) }
        }
        // The tiles' own glass chips (`TileGlass`): LIVE, then the name.
        .overlay(alignment: .topLeading) {
            HStack(spacing: Spacing.tight) {
                if content.isStream {
                    CallLiveBadge(isCompact: true)
                }
                Text(content.name)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(TileGlass.ink)
                    .lineLimit(1)
                    .padding(.horizontal, Spacing.base)
                    .frame(height: 20)
                    .tileGlass()
            }
            .padding(Spacing.base)
        }
        .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .onHover { isHovering = $0 }
        .animation(motion.hover, value: isHovering)
        .onTapGesture(count: 2) { model.returnToCall(content.channelID) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(content.isStream ? "\(content.name)'s stream" : "\(content.name)'s camera"))
    }

    private var controls: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                Button("Return to Call", systemImage: "arrow.up.backward.and.arrow.down.forward") {
                    model.returnToCall(content.channelID)
                }
                Button(model.isSelfMuted ? "Unmute" : "Mute", systemImage: model.isSelfMuted ? "mic.slash.fill" : "mic.fill") {
                    model.toggleVoiceMute()
                }
                if content.isStream {
                    Button("Stop Watching", systemImage: "eye.slash") {
                        model.toggleWatchingStream(content.userID)
                    }
                }
                Button("Leave Call", systemImage: "phone.down.fill") { model.leaveVoice() }
                    .tint(Palette.destructive)
            }
            .labelStyle(.glassCircleIcon)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(Spacing.base)
    }
}
