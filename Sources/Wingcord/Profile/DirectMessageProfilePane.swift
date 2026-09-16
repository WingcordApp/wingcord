import SwiftUI
import WingcordCore

/// Reads the store and hands the DM profile column its value.
///
/// A thin container, like every other surface's: the pane below holds no model
/// reference, so a message arriving cannot invalidate it and a presence flush
/// costs one comparison.
///
/// **It starts the fetch as well as reading it.** The roster knows a name and an
/// avatar; the banner, the bio, the badges and the theme colours are only on the
/// profile route, and nothing else on this screen asks for them. The request is
/// keyed on the person, so switching conversations cancels the outgoing one.
struct DirectMessageProfileContainer: View {
    var userID: UserID

    @Environment(AppModel.self) private var model

    var body: some View {
        DirectMessageProfilePane(
            profile: model.profilePresentation(for: ProfileRequest(
                userID: userID,
                guildID: nil,
                // The full profile opens as a sheet, which anchors to nothing.
                anchor: .zero,
                depth: .full
            )),
            openFullProfile: { model.openProfile(userID, anchor: .zero, depth: .full) },
            openLink: { model.openLink($0) },
            gameCollection: model.gameCollection(for: userID)
        )
        .task(id: userID) {
            model.sessionController.loadProfile(of: userID, inGuild: nil)
            // The card draws their current activity in full, and the links
            // behind its buttons are a route of their own — a presence carries
            // the labels and never the addresses.
            if let activity = model.presences[userID]?.primaryActivity {
                model.sessionController.loadActivityButtons(of: userID, activity: activity)
            }
        }
    }
}

/// The other person, beside a direct message.
///
/// **The card's own parts, in a column's form.** The banner with its cut-out,
/// the badge row, the status bubble and the role chips are defined once for the
/// popover; a sidebar that redrew all of them is a place for each to drift. What
/// differs is the *form* — and that is one parameter rather than a second view.
///
/// **The ground belongs to the pane, not to the content.** A card's ground stops
/// where its content stops, which in a column leaves the lower half of the
/// sidebar showing the transcript's black through it — a rounded card floating
/// at the top of an empty column with a shadow under it, which reads as
/// something that failed to load the rest of itself. Painting the pane means the
/// ground runs to the foot of the window however short the profile is, and the
/// scroll view inside it carries only the content.
struct DirectMessageProfilePane: View {
    var profile: ProfilePresentation?
    var openFullProfile: () -> Void
    /// Passed through to the card's prose. The pane holds no model reference —
    /// see the container above — so the opener arrives as a closure like every
    /// other action on this surface.
    var openLink: ((String) -> Void)?
    /// Their board's covers, resolved by the container for the same reason.
    var gameCollection: GameCollection?

    private static let width: CGFloat = Proportions.profileColumnIdeal

    private var ground: ProfileGround {
        // The pane paints the ground its card sits on, so it has to reach the
        // same answer — and this one is the sidebar. See `ProfileGround.isDark`.
        ProfileGround(
            themeColorValues: profile?.themeColorValues ?? [],
            followsAppTheme: true
        )
    }

    var body: some View {
        Group {
            if let profile {
                ScrollView {
                    MiniProfileCard(
                        profile: profile,
                        openFullProfile: openFullProfile,
                        openLink: openLink,
                        gameCollection: gameCollection,
                        width: Self.width,
                        form: .column
                    )
                }
                .scrollIndicators(.never)
                .softScrollEdgesVertical()
            } else {
                // A conversation whose other person has not arrived yet. Real
                // during bootstrap, and a column drawn empty says the same thing
                // as a column drawn broken.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // **A rounded box that fills the column, not a full-bleed region.**
        // Two things had to be true at once and each was tried alone first: the
        // ground has to run the height of the pane, or a short profile leaves
        // the lower half of the sidebar showing the transcript's black through
        // it — and it has to keep its corners, or the person's own surface stops
        // reading as an object and becomes a slab bolted to the window edge.
        //
        // Filling comes from the frame, the corners from the clip, and the inset
        // is what gives the corners somewhere to be.
        .frame(maxHeight: .infinity, alignment: .top)
        .modifier(ProfileGroundFill(
            ground: ground,
            corner: Radius.card,
            form: .card(topHold: MiniProfileCard.bannerHeight)
        ))
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(ground.borderStyle, lineWidth: ground.borderWidth)
        }
        .padding(Spacing.base)
        .frame(width: Self.width + Spacing.base * 2)
    }
}
