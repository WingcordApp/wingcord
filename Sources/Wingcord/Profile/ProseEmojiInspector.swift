import SwiftUI
import WingcordCore

/// The emoji somebody clicked in a block of prose, and where it is drawn.
struct ProseInspectedEmoji: Identifiable, Equatable {
    var emoji: EmojiRef
    /// In the prose canvas's own space.
    var rect: CGRect

    var id: String { "\(emoji.id?.rawValue ?? 0):\(emoji.name):\(rect.origin.x):\(rect.origin.y)" }
}

/// Presents an emoji's card beside the emoji, or installs nothing.
///
/// **Guarded, not short-circuited** — `INVARIANTS.md` §2: a presentation
/// written unconditionally is a node on every block of prose in the app, for
/// the few that sit on a profile.
struct ProseEmojiInspector: ViewModifier {
    var isOn: Bool
    @Binding var inspected: ProseInspectedEmoji?

    @Environment(AppModel.self) private var model: AppModel?

    func body(content: Content) -> some View {
        if isOn, let model {
            content.popover(
                item: $inspected,
                attachmentAnchor: .rect(.rect(inspected?.rect ?? .zero)),
                arrowEdge: .trailing
            ) { item in
                let request = ExpressionInfoRequest(subject: .emoji(item.emoji), anchor: .zero)
                ExpressionInfoCard(
                    info: model.expressionInfo(for: request),
                    openGuild: { model.openGuild($0) },
                    previewGuild: { model.previewFromExpression($0) }
                )
                .presentationBackground(.clear)
                // Started here rather than in the resolver: a resolver that
                // fires a request fires one every time a view body runs.
                .task(id: request.id) {
                    await model.loadExpressionSourceIfNeeded(for: request)
                }
            }
        } else {
            content
        }
    }
}
