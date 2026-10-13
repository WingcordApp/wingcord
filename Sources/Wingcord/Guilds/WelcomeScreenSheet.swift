import SwiftUI
import WingcordCore

/// Discord's "Explore the Server" (`954784`): a Community server's Welcome
/// Screen — the server, a sentence about it, and the "Top things to do here".
///
/// **One sheet for two callers**, as Discord's is one modal: a new member
/// greeted after an invite, and the settings page's Preview. Picking a channel
/// goes there; the footer's only button leaves the reader where they are.
struct WelcomeScreenSheet: View {
    var presentation: WelcomeScreenPresentation
    var openChannel: (ChannelID) -> Void

    @Environment(\.dismiss) private var dismiss

    private static let iconSide: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                content
                    .padding(.horizontal, Spacing.group)
                    .padding(.bottom, Spacing.margin)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .frame(width: 440)
        .background(Palette.surface)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Explore the Server")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Spacing.base)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.secondary)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    private var content: some View {
        VStack(spacing: Spacing.margin) {
            RemoteImage(url: presentation.iconURL, side: Self.iconSide) {
                Text(presentation.monogram)
                    .font(.system(size: Self.iconSide * 0.32, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: Self.iconSide, height: Self.iconSide)
                    .background(Palette.surfaceRaised)
            }
            .frame(width: Self.iconSide, height: Self.iconSide)
            .clipShape(.rect(cornerRadius: Self.iconSide * 0.3, style: .continuous))
            .accessibilityHidden(true)

            VStack(spacing: Spacing.base) {
                Text("Welcome to \(Text(verbatim: presentation.serverName).bold())")
                    .font(.system(.title2, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                if let description = presentation.description {
                    Text(verbatim: description)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("Top things to do here")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                ForEach(presentation.options) { option in
                    WelcomeOptionButton(option: option) {
                        dismiss()
                        openChannel(option.channelID)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Text("I'll just look around for now")
                    .font(.system(.body, weight: .medium))
                    .padding(.horizontal, Spacing.group)
                    .frame(height: Metrics.composerControlHeight)
                    .background(Palette.surfaceRaised, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Ink.primary)
            .overlay { Capsule().strokeBorder(Palette.edge) }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.margin)
    }
}

/// One of the "Top things to do here": its emoji — or the channel's own glyph
/// where it has none — the words, the channel, and a chevron.
private struct WelcomeOptionButton: View {
    var option: WelcomeScreenPresentation.Option
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.snug) {
                Group {
                    if let emoji = option.emoji {
                        ExpressionGlyph(emoji: emoji, side: 24, plays: isHovering)
                    } else {
                        Image(symbol: option.channelSymbol)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Ink.secondary)
                    }
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option.description)
                        .font(.system(.body))
                        .foregroundStyle(Ink.primary)
                    Label {
                        Text(verbatim: option.channelName)
                    } icon: {
                        Image(symbol: option.channelSymbol)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(Spacing.snug)
            .background(
                isHovering ? Palette.hoverFill : Palette.groupedFill,
                in: .rect(cornerRadius: Radius.row, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard hovering != isHovering else { return }
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
    }
}
