import AppKit
import SwiftUI

/// Why a profile opens behind a warning — see `AppModel.profileWarning`.
enum ProfileWarning: Sendable, Equatable {
    case blocked
    case ignored
}

/// Discord's "Show Profile?" — what stands in front of the profile of somebody
/// the reader blocked or ignored, until they say yes.
///
/// **Inside the person's own ground**, as Discord's sits inside their themed
/// profile: what the reader is about to look at is still recognisably theirs.
/// The card and the column show one of Discord's own pictures behind it — a
/// faint, blurred skeleton of a profile, not this person's — so the warning
/// reads as a profile held back rather than as an empty box.
///
/// Discord's own words throughout: `b33pLD`, `8F+WNz` and `/cZp5s` on the card,
/// `T7QiLn`, `MnEowy`, `kcuWva`, `QxrDY1` and `W6fjkS` on the full profile.
struct ProfileWarningView: View {
    enum Form {
        /// The popout beside a click.
        case card
        /// The column beside a direct message.
        case column
        /// A profile linked in a message.
        case embed
        /// The full profile.
        case sheet
    }

    var warning: ProfileWarning
    var name: String
    var avatarURL: URL?
    var monogram: String
    var form: Form
    /// The width it is laid out across — the card's, the column's or the
    /// sheet's. Its words take 80% of it, as Discord's `body` does.
    var width: CGFloat
    var reveal: () -> Void
    /// "Don't show this again", which Discord offers for an ignore only.
    var skip: () -> Void

    var body: some View {
        switch form {
        case .card, .column:
            ZStack(alignment: .top) {
                skeleton
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .embed, .sheet:
            content
                .frame(maxWidth: .infinity)
                .padding(.vertical, form == .sheet ? Spacing.group : Spacing.margin)
        }
    }

    /// Discord's skeleton, `filter: blur(5px)` at `opacity: .3`, fitted to the
    /// width and hung from the top.
    @ViewBuilder
    private var skeleton: some View {
        if let image = ProfileWarningArt.image(for: form) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // `filter: blur(5px)` is a Gaussian of deviation 5 — the same
                // deviation a SwiftUI blur's radius is.
                .blur(radius: 5)
                .opacity(0.3)
                .accessibilityHidden(true)
        }
    }

    private var content: some View {
        VStack(spacing: Spacing.margin) {
            VStack(spacing: Spacing.base) {
                badgedAvatar
                Text("Show Profile?")
                    .font(.system(size: form == .sheet ? 24 : 20, weight: .bold))
                    .foregroundStyle(InkColor.primary)
                    .accessibilityAddTraits(.isHeader)
                sentence
                    .font(.system(size: form == .sheet ? 16 : 14, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if form == .sheet {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    reassurance("They won\u{2019}t be notified")
                    reassurance(warning == .blocked ? "They will still be blocked" : "They will still be ignored")
                }
            }
            VStack(spacing: Spacing.base) {
                MessageRequestButton(title: "Yes, show profile", isProminent: true, isBusy: false, action: reveal)
                if warning == .ignored {
                    Button(action: skip) {
                        Text("Don\u{2019}t show this again")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(InkColor.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: width * 0.8)
    }

    /// Their face with Discord's mark on it — the block circle, or the eye with
    /// a slash for an ignore — 56 points, the mark hung off its lower corner.
    private var badgedAvatar: some View {
        AvatarView(url: avatarURL, monogram: monogram, side: 56)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: warning == .blocked ? "nosign" : "eye.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(InkColor.secondary)
                    .padding(4)
                    .background(Palette.groupedFill, in: .circle)
                    .offset(x: 8, y: 8)
            }
            .padding(.bottom, Spacing.tight)
            .accessibilityHidden(true)
    }

    /// The card's sentence carries the reassurance; the full profile lists it
    /// separately.
    private var sentence: Text {
        let lead = warning == .blocked ? "You blocked " : "You ignored "
        let tail: String
        switch (form, warning) {
        case (.sheet, _):
            tail = ", so just making sure."
        case (_, .blocked):
            tail = ", so just making sure. They won\u{2019}t be notified, and will still be blocked"
        case (_, .ignored):
            tail = ", so just making sure. They won\u{2019}t be notified, and will still be ignored"
        }
        return Text("\(lead)\(Text(name).bold())\(tail)")
    }

    private func reassurance(_ text: String) -> some View {
        Label {
            Text(text).font(.system(size: 16))
        } icon: {
            Image(systemName: "checkmark.circle.fill")
        }
        .foregroundStyle(InkColor.primary)
    }
}

/// Discord's two skeletons, read from the bundle once each.
private enum ProfileWarningArt {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor static func image(for form: ProfileWarningView.Form) -> NSImage? {
        let name: String
        switch form {
        case .card: name = "profile-warning-card"
        case .column: name = "profile-warning-column"
        case .embed, .sheet: return nil
        }
        if let hit = cache[name] { return hit }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Art"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        cache[name] = image
        return image
    }
}
