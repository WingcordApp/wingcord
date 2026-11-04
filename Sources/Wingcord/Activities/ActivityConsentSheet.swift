import SwiftUI
import WingcordCore

/// "Watch Together wants to access your Discord account."
///
/// **Raised by the running activity, not by the Launch button.** The captured
/// order is launch, then frame, then this: the app asks for a grant over its
/// own channel once it is already running, and what it is waiting for is an
/// authorization code. Dismissing without answering is a refusal, and the
/// request is answered either way — a frame left waiting on a promise nobody
/// resolves is an activity that hangs on a blank screen.
///
/// **The permissions are in this app's own words.** `OAuthScope` already
/// carries the table — it was written for the Authorized Apps pane — and this
/// asks the same question about the same strings. Discord's consumer copy is
/// that client's design, not a fact on the wire; the wire only ever sends the
/// raw scope. Its joke line ("Buy you a nice seafood dinner") is not
/// reproduced for the same reason.
struct ActivityConsentSheet: View {
    var request: ActivityConsentRequest

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @ModalDismiss private var dismiss
    @State private var isAuthorizing = false

    private static let width: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            permissions
            footer
        }
        .frame(width: Self.width)
        // Every path out of here answers the request. **Including this one** —
        // a card closed with Escape or thrown away still has a frame behind
        // it waiting for a code.
        .onDisappear { request.answer(nil) }
    }

    // MARK: Header

    /// The app and the account, side by side.
    ///
    /// Two marks with the relationship drawn between them, because that is what
    /// the question is about: this app, and *your* account.
    private var header: some View {
        VStack(spacing: Spacing.snug) {
            HStack(spacing: Spacing.snug) {
                appIcon
                Image(systemName: "ellipsis")
                    .font(.system(.footnote, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
                accountIcon
            }
            VStack(spacing: Spacing.tight) {
                Text(request.authorization.name)
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(Ink.primary)
                Text("wants to access your Discord account")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    private var appIcon: some View {
        let side: CGFloat = 56
        let url = request.authorization.iconHash.flatMap {
            CDN.applicationIcon(id: request.authorization.applicationID, hash: $0, side: side)
        }
        return RemoteImage(url: url, side: side) {
            Text(String(request.authorization.name.prefix(1)).uppercased())
                .font(.system(size: side * 0.4, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: side, height: side)
                .background(Palette.surfaceRaised)
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: side * 0.28, style: .continuous))
    }

    @ViewBuilder
    private var accountIcon: some View {
        let side: CGFloat = 56
        if let user = model.currentUserID.flatMap({ model.users[$0] }) {
            AvatarView(
                url: model.avatarURL(for: user, side: side),
                monogram: AppModel.monogram(of: user.displayName ?? user.username),
                side: side
            )
        }
    }

    // MARK: Permissions

    /// What the grant actually allows, one line each.
    ///
    /// **Scrolls rather than truncating.** A grant with nine scopes on it is a
    /// grant somebody should be able to read all of before agreeing, and a
    /// list that clips at the sheet's edge hides exactly the rows a long grant
    /// added.
    private var permissions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Text("This will allow \(request.authorization.name) to:")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)

                ForEach(request.permissions, id: \.self) { permission in
                    Label {
                        Text(permission)
                            .font(.system(.subheadline))
                            .foregroundStyle(Ink.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Ink.tertiary)
                    }
                }

                policies
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.margin)
        }
        .frame(maxHeight: 260)
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip, style: .continuous))
        .padding(.horizontal, Spacing.group)
    }

    @ViewBuilder
    private var policies: some View {
        let terms = request.authorization.termsOfServiceURL
        let privacy = request.authorization.privacyPolicyURL
        if terms != nil || privacy != nil {
            Divider().padding(.vertical, Spacing.tight)
            HStack(spacing: Spacing.base) {
                Image(systemName: "lock")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
                if let terms {
                    Link("Terms", destination: terms)
                }
                if let privacy {
                    Link("Privacy", destination: privacy)
                }
                Spacer(minLength: 0)
            }
            .font(Typeface.rowSubtitle)
            .tint(Palette.accent)
        }
    }

    // MARK: Footer

    private var footer: some View {
        GlassEffectContainer(spacing: Spacing.snug) {
            HStack(spacing: Spacing.snug) {
                ModalButton(title: "Cancel", symbolName: "xmark", role: .cancel) {
                    request.answer(nil)
                    dismiss()
                }
                Spacer(minLength: 0)
                ModalButton(
                    title: "Authorize",
                    symbolName: "checkmark.shield.fill",
                    role: .act,
                    isWorking: isAuthorizing,
                    action: authorize
                )
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.margin)
    }

    private func authorize() {
        isAuthorizing = true
        Task {
            let code = await model.sessionController.authorizeActivity(request)
            isAuthorizing = false
            // Answered here rather than in `onDisappear`, so the frame gets the
            // code before the sheet's dismissal animation has finished. The
            // request answers once and ignores the second call.
            request.answer(code)
            dismiss()
        }
    }
}
