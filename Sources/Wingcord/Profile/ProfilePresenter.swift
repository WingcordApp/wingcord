import SwiftUI
import WingcordCore

/// The one place a profile is presented.
///
/// Attached at the window root and nowhere else. Every row that can open a
/// profile — a member row, a message avatar, a mention — sets
/// `AppModel.profileRequest` and stops there, which is what keeps presentation
/// modifiers off the rows themselves. A `.popover` written inline in a member
/// row is a popover *per row*, evaluated as part of every row's body on every
/// evaluation, including its content closure's captures.
///
/// **The card is a real `.popover`, not a hand-placed overlay**, and that is a
/// correctness decision rather than a shortcut. A popover already knows how to
/// anchor itself to a rect, keep itself inside the screen, dismiss on an outside
/// click, dismiss on Escape, and take first responder back cleanly. Rebuilding
/// those means a local `NSEvent` monitor — which has to be removed by hand, and
/// which keeps its closure and everything it captured alive for the life of the
/// process if it is not.
struct ProfilePresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .popover(
                item: request(at: .mini),
                // The anchor is the frame of the row that opened it, in this
                // view's coordinates — which is the window's, because this
                // modifier is applied at the root and nowhere else. A card that
                // appears at the pointer reads as a menu; one that appears
                // beside its row reads as belonging to that person.
                attachmentAnchor: .rect(.rect(model.profileRequest?.anchor ?? .zero)),
                arrowEdge: .leading
            ) { request in
                if let profile = model.profilePresentation(for: request) {
                    // The popover supplies no material of its own, so the card's
                    // is the only one. Without this an unthemed card's glass is
                    // stacked on the popover's own backing — glass on glass, §4
                    // rule 2 — and two materials in series read as frosted
                    // rather than as glass.
                    MiniProfileCard(
                        profile: profile,
                        openFullProfile: {
                            // Set the new depth synchronously, before the
                            // popover closes. Deferring a presentation by a
                            // timer to let the first one dismiss is a race that
                            // gets lost: the flag lives on the store while the
                            // code setting it runs inside a view being torn
                            // down, and a missed window drops the request
                            // silently — leaving the flag set so the next
                            // attempt no-ops too.
                            model.profileRequest?.depth = .full
                        }
                    )
                    .presentationBackground(.clear)
                }
            }
            // The full profile is a sheet rather than a second window: it is
            // modal to the conversation, and a window would outlive the account
            // switch that invalidates everything in it.
            .sheet(item: request(at: .full)) { request in
                if let profile = model.profilePresentation(for: request) {
                    FullProfileView(
                        profile: profile,
                        openDirectMessage: { model.openDirectMessage($0) },
                        dismiss: { model.profileRequest = nil }
                    )
                }
            }
    }

    /// A binding that presents the request only at `depth`.
    ///
    /// **The setter may only clear the store when the store is still AT that
    /// depth**, and getting that wrong is why the full profile could not be
    /// opened at all. Raising it is one write — `profileRequest?.depth = .full`
    /// — which makes the popover's `get` answer nil, so SwiftUI dismisses the
    /// card and, on the way out, calls the setter with nil. A setter that
    /// clears unconditionally then wipes the request it was just handed: the
    /// card closed, the sheet's `get` found nothing, and the click read as
    /// "dismiss and do nothing".
    ///
    /// With the guard, that dismissal is a no-op — the store is already at
    /// `.full` and this binding is the `.mini` one — and only a real dismissal,
    /// where the depth still matches, clears anything.
    private func request(at depth: ProfileRequest.Depth) -> Binding<ProfileRequest?> {
        Binding(
            get: {
                model.profileRequest?.depth == depth ? model.profileRequest : nil
            },
            set: { newValue in
                guard newValue == nil, model.profileRequest?.depth == depth else { return }
                model.profileRequest = nil
            }
        )
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsProfiles() -> some View {
        modifier(ProfilePresenter())
    }
}
