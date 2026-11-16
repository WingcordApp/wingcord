import SwiftUI

/// The hub's toolbar row: its name in the middle where every page's is, and its
/// controls at the trailing end.
///
/// **On the row, not in a bar along the window's foot** as Discord's save bar
/// is — macOS: "Avoid controls/critical information at the window bottom (the
/// window may be moved below the screen edge)". Viewing, an editor has Edit and
/// Settings; editing, Add Widget, Cancel and Save, which materialize in their
/// place inside one glass container, so the row reads as one set changing.
struct ServerHubBar: View {
    var presentation: ServerHubPresentation

    @Environment(\.motion) private var motion

    var body: some View {
        PageHeaderBar {
            EmptyView()
        } center: {
            HeaderTitleCapsule()
        } trailing: {
            if presentation.canEdit, presentation.phase == .ready {
                GlassEffectContainer(spacing: Spacing.base) {
                    HStack(spacing: Spacing.base) {
                        if presentation.isEditing {
                            ServerHubEditingControls(presentation: presentation)
                                .transition(.materialize(from: .trailing))
                        } else {
                            ServerHubViewingControls()
                                .transition(.materialize(from: .trailing))
                        }
                    }
                }
                .animation(motion.glassMorph, value: presentation.isEditing)
                .animation(motion.glassMorph, value: presentation.saveState)
            }
        }
    }
}
