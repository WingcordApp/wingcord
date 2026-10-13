import SwiftUI
import WingcordCore

/// The Rich Presence builder (DESIGN-NOTES §11, Alex's idea): the reader's own
/// presences in the Activity tab while the profile is being edited. Each card
/// is the one everybody else will see, edited where it sits, and **+** adds
/// another. One is on at a time.
///
/// **Saved as typed**, on this Mac, outside the profile's own Save: these are
/// not part of the Discord profile, and a card that is on goes out a beat
/// after the typing stops (`AppModel.customPresenceChanged`).
struct RichPresenceEditorPane: View {
    var ground: ProfileGround

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(settings.customPresences) { presence in
                ProfileSlab(ground: ground) {
                    EditablePresenceCard(
                        presence: presence,
                        isOn: settings.activeCustomPresenceID == presence.id,
                        ground: ground,
                        update: { model.updateCustomPresence($0) },
                        turnOn: { model.setCustomPresenceOn($0 ? presence.id : nil) },
                        remove: { model.removeCustomPresence(presence.id) }
                    )
                }
                .transition(.opacity)
            }
            AddPresenceSlab(ground: ground) { model.addCustomPresence() }
        }
        .padding(.top, Spacing.base)
        .animation(motion.standard, value: settings.customPresences.map(\.id))
    }
}

/// The builder's **+**: a slab-shaped outline where the next card goes.
private struct AddPresenceSlab: View {
    var ground: ProfileGround
    var add: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: add) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isHovering ? InkColor.primary : InkColor.secondary)
                .frame(maxWidth: .infinity, minHeight: CurrentActivityCard.artworkSide + 2 * Spacing.base)
                .background {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(isHovering ? InkColor.secondary : InkColor.tertiary)
                }
                .contentShape(.rect(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Add")
        .accessibilityLabel(Text("Add"))
    }
}
