import SwiftUI
import WingcordCore

/// The one place an expression card is presented.
///
/// Attached at the window root and nowhere else. The transcript is a **drawn
/// canvas**, so it cannot host a popover at all — a click on an emoji sets
/// `AppModel.expressionInfoRequest` with the picture's rect and stops there, and
/// this presents beside that rect.
///
/// A real `.popover` rather than a hand-placed overlay, for the same reasons the
/// profile card is one: it already knows how to keep itself on screen, dismiss
/// on an outside click, dismiss on Escape and give first responder back. Each of
/// those rebuilt by hand is a local `NSEvent` monitor that has to be removed and
/// keeps everything it captured alive if it is not.
struct ExpressionInfoPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.popover(
            item: $model.expressionInfoRequest,
            // Anchored to the emoji or sticker that was clicked, in this view's
            // coordinates — which are the window root's, because this modifier
            // is applied there and nowhere else.
            attachmentAnchor: .rect(.rect(model.expressionInfoRequest?.anchor ?? .zero)),
            arrowEdge: .trailing
        ) { request in
            ExpressionInfoCard(
                info: model.expressionInfo(for: request),
                openGuild: { model.openGuild($0) },
                openStickerPack: model.canOpenStickerPicker
                    ? { model.openStickerPicker(at: $0) }
                    : nil
            )
            // The card supplies its own material, so the popover must supply
            // none — two in series read as frost rather than as glass.
            .presentationBackground(.clear)
            // **Started here, not in the resolver.** A resolver that fires a
            // request fires one every time a view body runs; a `.task` keyed on
            // the request fires once per card and is cancelled with it.
            .task(id: request.id) {
                await model.loadExpressionSourceIfNeeded(for: request)
            }
        }
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsExpressionInfo() -> some View {
        modifier(ExpressionInfoPresenter())
    }
}

/// The expression card, opened from **inside** another popover.
///
/// **A nested popover rather than the routed request**, for the reason
/// `GuildTagChip` is one: a view inside a popover has no meaningful rect in the
/// window root's space, so it cannot use the anchor the root presenter needs.
/// Nested popovers were confirmed on screen rather than assumed — see
/// `HANDOFF.md`.
///
/// One per profile surface, keyed on the emoji that was clicked — not one per
/// emoji in the prose, which would be a presentation node per picture in
/// somebody's bio.
struct ExpressionInfoPopover: ViewModifier {
    @Binding var emoji: EmojiRef?

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { emoji != nil },
                set: { if !$0 { emoji = nil } }
            ),
            arrowEdge: .trailing
        ) {
            if let emoji {
                let request = ExpressionInfoRequest(subject: .emoji(emoji), anchor: .zero)
                ExpressionInfoCard(
                    info: model.expressionInfo(for: request),
                    openGuild: { model.openGuild($0) }
                )
                .presentationBackground(.clear)
                // Started here rather than in the resolver: a resolver that
                // fires a request fires one every time a view body runs.
                .task(id: request.id) {
                    await model.loadExpressionSourceIfNeeded(for: request)
                }
            }
        }
    }
}

extension View {
    /// Shows the expression card for `emoji`, beside this surface.
    func presentsExpressionInfo(for emoji: Binding<EmojiRef?>) -> some View {
        modifier(ExpressionInfoPopover(emoji: emoji))
    }
}
