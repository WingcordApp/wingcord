import AppKit
import SwiftUI
import WingcordCore

/// One clip, recording or screenshot in the library's grid — its picture,
/// how long it runs, who was in it, what it was of and when.
struct ClipCard: View {
    var item: ClipLibraryItem
    var isFavourite: Bool
    var isSelected: Bool
    /// Recent's larger cards.
    var isLarge = false

    @Environment(\.motion) private var motion
    @State private var picture: CGImage?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(isLarge ? .headline : .subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(caption)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .task(id: item.url) {
            picture = await ClipThumbnails.shared.thumbnail(for: item.url, kind: item.kind)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kindName), \(item.title)")
        .accessibilityValue(caption)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var artwork: some View {
        ZStack {
            Rectangle().fill(Ink.quaternary)
            if let picture {
                Image(decorative: picture, scale: 2)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(symbol: kindSymbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Ink.tertiary)
            }
            // The moving ones say so, and how long they run.
            VStack {
                HStack(alignment: .top) {
                    if item.kind != .clip {
                        badge(symbol: kindSymbol)
                    }
                    // Auto Clips' reason, in Discord's words.
                    if let reason = item.autoReason {
                        Label(reason.label, systemImage: "sparkles")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: .capsule)
                    }
                    Spacer()
                    if isFavourite {
                        badge(symbol: "star.fill", tint: .yellow)
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    faces
                    Spacer()
                    if let duration = item.duration {
                        Text(Duration.seconds(duration.rounded()).formatted(.time(pattern: .minuteSecond)))
                            .font(.system(.caption, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: .capsule)
                    }
                }
            }
            .padding(Spacing.base)
            if isHovered, item.kind != .screenshot {
                Image(symbol: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.45), in: .circle)
                    .transition(.opacity)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Palette.accent : .clear, lineWidth: 3)
        }
        .animation(motion.hover, value: isHovered)
        .animation(motion.hover, value: picture != nil)
    }

    private func badge(symbol: String, tint: Color = .white) -> some View {
        Image(symbol: symbol)
            .font(.system(.caption, weight: .bold))
            .foregroundStyle(tint)
            .padding(5)
            .background(.black.opacity(0.5), in: .circle)
    }

    /// Up to four faces, as Discord's player header draws them.
    @ViewBuilder private var faces: some View {
        let people = item.participants
        if !people.isEmpty {
            HStack(spacing: -6) {
                ForEach(Array(people.prefix(4).enumerated()), id: \.offset) { _, person in
                    AvatarView(url: person.avatarURL, monogram: String(person.name.prefix(1)).uppercased(), side: 20)
                        .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1.5))
                }
                if people.count > 4 {
                    Text("+\(people.count - 4)")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.leading, 9)
                }
            }
        }
    }

    private var kindName: String {
        switch item.kind {
        case .clip: "Clip"
        case .recording: "Recording"
        case .screenshot: "Screenshot"
        }
    }

    private var kindSymbol: String {
        switch item.kind {
        case .clip: "film"
        case .recording: "record.circle"
        case .screenshot: "camera.viewfinder"
        }
    }

    private var caption: String {
        var parts: [String] = []
        if let game = item.game { parts.append(game) }
        parts.append(item.clip.created.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }
}
