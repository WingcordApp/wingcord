import AppKit
import SwiftUI
import WingcordCore

/// What the reply bar over the composer says about the message being answered.
struct ComposerReply: Equatable {
    /// Their name as the server knows them.
    var name: String
    /// Their role colour, or nil for the plain ink.
    var colorValue: UInt32?
    /// Their role's gradient, where it has one — the same role as the colour.
    var gradient: [UInt32]?
    /// Their display-name style's face, at the bar's size, or nil for the
    /// system's. **The face only**: Discord hands this bar
    /// `displayNameStylesFont` and nothing else of the style.
    var face: NSFont?
    var tracking: CGFloat = 0
    /// Whether the reply pings them — Discord's mention toggle.
    var pings: Bool
    /// Whether the toggle is offered: in a server, and never on the reader's
    /// own message (Discord's `showMentionToggle: !isPrivate && !isMe`).
    var showsMentionToggle: Bool
}

/// Discord's reply bar (`tc`, chunk `9494e99e…`): "Replying to" and the name in
/// their role colour and their style's face, a jump to the message on the
/// label, the **@ ON / OFF** toggle, and ✕.
struct ReplyBar: View {
    var reply: ComposerReply
    var jump: () -> Void
    var togglePing: () -> Void
    var cancel: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
                .accessibilityHidden(true)
            Button(action: jump) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Replying to \(reply.name)"))
            Spacer(minLength: Spacing.tight)
            if reply.showsMentionToggle {
                mentionToggle
                Rectangle()
                    .fill(Ink.quaternary)
                    .frame(width: 1, height: 14)
                    .accessibilityHidden(true)
            }
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel reply"))
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.chip))
    }

    private var label: some View {
        HStack(spacing: 0) {
            Text("Replying to ")
                .foregroundStyle(Ink.secondary)
            name
        }
        .font(.system(.caption))
        .lineLimit(1)
        .contentShape(.rect)
    }

    /// Semibold (`.name { font-weight: semibold }`), in their face where they
    /// chose one.
    private var name: some View {
        Text(reply.name)
            .font(reply.face.map { Font($0 as CTFont) } ?? .system(.caption, weight: .semibold))
            .tracking(reply.tracking)
            .foregroundStyle(nameInk)
    }

    private var nameInk: AnyShapeStyle {
        if let stops = reply.gradient, stops.count > 1 {
            return AnyShapeStyle(LinearGradient(
                colors: stops.map { Color(hex: $0) },
                startPoint: .leading,
                endPoint: .trailing
            ))
        }
        if let colorValue = reply.colorValue { return AnyShapeStyle(Color(hex: colorValue)) }
        return AnyShapeStyle(Ink.primary)
    }

    /// "@ ON" in the link colour, "@ OFF" muted — Discord's `mentionButton`,
    /// bold and in capitals.
    private var mentionToggle: some View {
        Button(action: togglePing) {
            HStack(spacing: 3) {
                Image(systemName: "at")
                    .font(.system(.caption, weight: .bold))
                Text(reply.pings ? "ON" : "OFF")
                    .font(.system(.caption, weight: .bold))
            }
            .foregroundStyle(reply.pings ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
            .padding(.horizontal, Spacing.tight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(reply.pings
            ? "Click to disable pinging the original author."
            : "Click to enable pinging the original author.")
        .accessibilityLabel(Text("Mention"))
        .accessibilityValue(Text(reply.pings ? "ON" : "OFF"))
        .accessibilityAddTraits(.isToggle)
    }
}
