import SwiftUI
import WingcordCore

/// Discord's invite modal (`777307`), on this app's card: who's inviting you to
/// what, what you'd be joining as, and a slide to accept it.
///
/// **Two columns when the invite has its own picture, one when it doesn't**, as
/// Discord's `xl` and `sm`. The picture takes 520 points, or 300 in a window with
/// no room for that, Discord's own two widths.
struct InviteAcceptSheet: View {
    var state: InviteSheetState
    var presentation: InviteSheetPresentation?
    var setNickname: (String) -> Void
    var setAllowsDirectMessages: (Bool) -> Void
    var setShowsActivity: (Bool) -> Void
    var accept: () -> Void
    var openNitro: () -> Void
    var dismiss: () -> Void

    @Environment(\.motion) private var motion
    @State private var isSettingsOpen = false

    /// Discord's own 424 or so, with air for the slide.
    private static let contentWidth: CGFloat = 440

    var body: some View {
        Group {
            switch state.phase {
            case .looking:
                ProgressView()
                    .controlSize(.regular)
                    .frame(width: Self.contentWidth, height: 200)
                    .accessibilityLabel(Text("Loading the invite"))
            case .invalid:
                ModalAlert(
                    hero: .symbol("exclamationmark.triangle.fill", tint: .orange),
                    title: "The invite link is invalid or has expired.",
                    message: Text("Try using a different link to join this server."),
                    actions: [.okay("Got it")]
                )
            case .ready:
                if let presentation { ready(presentation) }
            }
        }
        .animation(motion.reposition, value: isSettingsOpen)
        .animation(motion.standard, value: state.failure)
        .modalDismissDisabled(state.isAccepting)
        // A captcha is raised from inside the accept, and this card covers the
        // window root, as `JoinServerSheet`'s does.
        .captchaHost()
    }

    private func ready(_ presentation: InviteSheetPresentation) -> some View {
        Group {
            if let splash = presentation.splashURL {
                ViewThatFits(in: .horizontal) {
                    twoColumns(presentation, splash: splash, width: 520)
                    twoColumns(presentation, splash: splash, width: 300)
                }
            } else {
                content(presentation).frame(width: Self.contentWidth)
            }
        }
    }

    /// **The column decides the height and the picture follows it.** As a sibling
    /// in a stack, a picture's flexible frame took the window's whole height.
    private func twoColumns(_ presentation: InviteSheetPresentation, splash: URL, width: CGFloat) -> some View {
        content(presentation)
            .frame(width: Self.contentWidth)
            .padding(.trailing, width)
            .background(alignment: .trailing) {
                Color.clear
                    .frame(width: width)
                    .overlay {
                        RemoteImage(url: splash, side: width, bucket: .artwork, arrival: motion.fade) {
                            Rectangle().fill(Palette.surfaceRaised)
                        }
                        .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                    .accessibilityHidden(true)
            }
    }

    // MARK: The column

    private func content(_ presentation: InviteSheetPresentation) -> some View {
        VStack(spacing: Spacing.section) {
            heading(presentation)
            foot(presentation)
        }
        .padding(Spacing.group)
        .padding(.top, Spacing.group)
        .frame(minHeight: 340, alignment: .top)
    }

    private func heading(_ presentation: InviteSheetPresentation) -> some View {
        VStack(spacing: Spacing.base) {
            icon(presentation)
                .padding(.bottom, Spacing.tight)
            if let failure = state.failure {
                // Discord's own: the name makes way for why it didn't work.
                Text("Whoops...")
                    .font(.system(.body))
                    .foregroundStyle(Ink.primary)
                Text(failure)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let lead = presentation.lead {
                    Text(lead)
                        .font(.system(.body))
                        .foregroundStyle(Ink.primary)
                        .multilineTextAlignment(.center)
                }
                title(presentation)
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.system(.body))
                        .foregroundStyle(Ink.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            counts(presentation)
            if !presentation.roles.isEmpty {
                rolesGranted(presentation.roles)
                    .padding(.top, Spacing.base)
            }
            if presentation.offersSettings {
                settings(presentation)
                    .padding(.top, Spacing.snug)
            }
        }
    }

    private func title(_ presentation: InviteSheetPresentation) -> some View {
        HStack(spacing: Spacing.tight + Spacing.hair) {
            if let mark = presentation.mark {
                GuildMarkBadge(mark: mark, side: 22)
            }
            Text(presentation.title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func icon(_ presentation: InviteSheetPresentation) -> some View {
        let shape: AnyShape = presentation.iconIsRound
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 64 * 0.3, style: .continuous))
        return RemoteImage(url: presentation.iconURL, side: 64) {
            Text(presentation.monogram)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Ink.primary)
                .frame(width: 64, height: 64)
                .background(Palette.surfaceRaised)
        }
        .frame(width: 64, height: 64)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    /// Discord's two pills, drawn wherever it was told the numbers. A count
    /// nobody has is left out rather than drawn as zero.
    @ViewBuilder
    private func counts(_ presentation: InviteSheetPresentation) -> some View {
        if presentation.memberCount != nil {
            HStack(spacing: Spacing.margin) {
                if let online = presentation.onlineCount, online > 0 {
                    count("\(online.formatted()) Online", dot: Palette.presenceOnline)
                }
                if let members = presentation.memberCount {
                    count(members == 1 ? "1 Member" : "\(members.formatted()) Members", dot: Ink.secondary)
                }
            }
            .padding(.top, Spacing.hair)
        }
    }

    private func count(_ words: String, dot: some ShapeStyle) -> some View {
        HStack(spacing: Spacing.tight) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(words)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.primary)
        }
    }

    private func rolesGranted(_ roles: [InviteGrantedRole]) -> some View {
        VStack(spacing: Spacing.tight + Spacing.hair) {
            Text("Roles Granted")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.primary)
            FlowLayout(spacing: Spacing.tight) {
                ForEach(roles) { role in
                    HStack(spacing: Spacing.tight) {
                        Circle()
                            .fill(role.colorValue.map { Color(hex: $0) } ?? InkColor.secondary)
                            .frame(width: 10, height: 10)
                        Text(role.name)
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Spacing.base)
                    .frame(height: 24)
                    .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.chip, style: .continuous))
                }
            }
        }
    }

    // MARK: Server Settings

    private func settings(_ presentation: InviteSheetPresentation) -> some View {
        VStack(spacing: 0) {
            Button {
                isSettingsOpen.toggle()
            } label: {
                HStack(spacing: Spacing.snug) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Ink.primary)
                        .frame(width: 36, height: 36)
                        .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.row, style: .continuous))
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text("Server Settings")
                            .font(.system(.body, weight: .medium))
                            .foregroundStyle(Ink.primary)
                        Text("You can customize these at any time")
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .rotationEffect(.degrees(isSettingsOpen ? 90 : 0))
                }
                .padding(Spacing.snug)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(isSettingsOpen ? "Expanded" : "Collapsed"))

            if isSettingsOpen {
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    if presentation.offersNickname {
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text("Server Nickname")
                                .font(.system(.subheadline, weight: .medium))
                                .foregroundStyle(Ink.primary)
                            ModalTextField(
                                placeholder: "What should everyone call you?",
                                text: Binding(get: { state.nickname }, set: setNickname)
                            )
                        }
                        Divider()
                    }
                    switchRow(
                        "Allow direct messages",
                        isOn: Binding(get: { state.allowsDirectMessages }, set: setAllowsDirectMessages)
                    )
                    if presentation.offersActivity {
                        Divider()
                        switchRow(
                            "Show your activity status",
                            isOn: Binding(get: { state.showsActivity }, set: setShowsActivity)
                        )
                    }
                }
                .padding(.horizontal, Spacing.snug)
                .padding(.bottom, Spacing.snug)
                .transition(.opacity)
            }
        }
        .background(Palette.groupedFill, in: .rect(cornerRadius: Radius.row + 2, style: .continuous))
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Ink.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: The foot

    private func foot(_ presentation: InviteSheetPresentation) -> some View {
        VStack(spacing: Spacing.snug) {
            if presentation.isAtServerLimit {
                serverLimitNotice
            }
            if let expiry = presentation.expiry {
                Text(expiry)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
            }
            SlideToConfirm(
                title: presentation.slideTitle(nickname: state.nickname),
                accessibilityTitle: presentation.accessibilityTitle(nickname: state.nickname),
                isWorking: state.isAccepting,
                lockedTitle: presentation.isAtServerLimit ? "You are at the 100 server limit" : nil,
                confirm: accept
            ) {
                AvatarView(
                    url: presentation.accountAvatarURL,
                    monogram: presentation.accountMonogram,
                    side: 34
                )
            }
            ModalButton(title: "No Thanks", role: .cancel, action: dismiss)
                .disabled(state.isAccepting)
        }
    }

    private var serverLimitNotice: some View {
        Button(action: openNitro) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Palette.accent)
                Text("Upgrade to Discord Nitro to join up to 200 servers!")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: Spacing.tight)
                Text("Get Nitro")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            .padding(Spacing.base)
            .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.row, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
