import SwiftUI

/// A server's Server Hub: its banner, then its widgets in two columns.
///
/// **Content on standard material, controls on glass** (HIG: "Don't use Liquid
/// Glass in the content layer"; INVARIANTS §4). The banner and the cards are
/// content. What floats is glass: the page's row at the top — Edit and
/// Settings, and in an edit Add Widget, Cancel and Save — and, only while
/// editing, each card's own controls and the banner's.
struct ServerHubPage: View {
    var presentation: ServerHubPresentation

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        @Bindable var hub = model.serverHub
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.group) {
                if presentation.showsDraftNotice {
                    ServerHubDraftNotice(isPublishing: presentation.isPublishing)
                        .transition(.opacity)
                }
                ServerHubBanner(
                    header: presentation.header,
                    isEditing: presentation.isEditing,
                    isSaving: presentation.saveState == .saving
                )
                ServerHubPageBody(presentation: presentation)
            }
            .frame(maxWidth: ServerHubMetrics.pageWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.group)
            .padding(.top, Spacing.snug)
            .padding(.bottom, Spacing.section)
        }
        .scrollBounceBehavior(.always, axes: .vertical)
        .floatingTopBar {
            ServerHubBar(presentation: presentation)
        }
        .animation(motion.reposition, value: presentation.isEditing)
        .animation(motion.standard, value: presentation.showsDraftNotice)
        .sheet(item: $hub.sheet) { sheet in
            ServerHubSheetContent(sheet: sheet, presentation: presentation)
        }
    }
}
