import SwiftUI
import WingcordCore

/// The author's voice channel under the hero — Discord's voice bar (`cj`):
/// the server, a chevron, the room's name, up to three faces, and Join (or
/// Watch while they stream).
struct ActivityVoiceBar: View {
    var voice: ActivityPopoutPresentation.VoiceBar
    var join: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: 6) {
                RemoteImage(url: voice.guildIconURL, side: 16) {
                    Text(voice.guildMonogram)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Color.white.opacity(0.12))
                }
                .frame(width: 16, height: 16)
                .clipShape(.rect(cornerRadius: 5, style: .continuous))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.5))
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.8))
                Text(voice.channelName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: Spacing.base)
                HStack(spacing: -4) {
                    ForEach(Array(voice.faces.enumerated()), id: \.offset) { _, face in
                        AvatarView(url: face.url, monogram: face.monogram, side: 16)
                            .overlay { Circle().strokeBorder(ActivityCardPopout.ground, lineWidth: 1.5) }
                    }
                }
                if voice.extraCount > 0 {
                    Text("+\(voice.extraCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(height: 16)
                        .background(Color.white.opacity(0.12), in: .rect(cornerRadius: 8, style: .continuous))
                }
            }
            if !voice.isReaderHere || voice.isStreaming {
                Button(action: join) {
                    Label(voice.isStreaming ? "Watch" : "Join", systemImage: voice.isStreaming ? "display" : "speaker.wave.2.fill")
                        .font(.system(.subheadline, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
