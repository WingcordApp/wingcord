import SwiftUI
import WingcordCore

/// Add a Server.
///
/// One field, and a card that appears under it once the code resolves. **The
/// card is the whole design**: an invite is seven opaque characters, and a
/// dialog that takes them and joins on faith is one typo away from putting
/// somebody in a server they have never heard of. Discord's own dialog shows
/// nothing until you press Join; this resolves as you type and shows what is
/// behind the code, which is the question anybody pasting one actually has.
struct JoinServerSheet: View {
    var state: JoinServerSheetState
    var setInput: (String) -> Void
    var join: () -> Void
    var dismiss: () -> Void

    private static let width: CGFloat = 460

    @Environment(\.motion) private var motion
    @FocusState private var isFieldFocused: Bool
    /// The field's own text.
    ///
    /// **`@State` plus `onChange`, not a `Binding(get:set:)` over the store.**
    /// The field is the only thing that writes this, so a two-way binding buys
    /// nothing — and a hand-built binding in a view body converts a non-Sendable
    /// closure into a `@Sendable` one, which Swift 6 is right to complain about.
    /// The store's copy is what the resolve compares its answer against; it is
    /// written on the way out, one line below.
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            field
            preview
            footer
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Ink.quaternary, lineWidth: 1)
        }
        .presentationBackground(.clear)
        // A sheet that opens with its one field unfocused is a sheet that asks
        // for a click before it can be used for the thing it exists for.
        .onAppear {
            isFieldFocused = true
            // Seeded rather than assumed empty: the store is the surviving copy
            // if this sheet is ever reopened onto a lookup already in flight.
            if input != state.input { input = state.input }
        }
        .onChange(of: input) { _, value in setInput(value) }
        .animation(motion.standard, value: state.preview)
        .animation(motion.standard, value: state.failureMessage)
        .animation(motion.fadeQuick, value: state.isLooking)
        // The captcha is raised from inside the join below, and this sheet
        // covers the window root — so without a host here the challenge has
        // nowhere to appear and the join reports Discord's rejection instead.
        .captchaHost()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Join a Server")
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(Ink.primary)
            Text("Enter an invite below to join an existing server.")
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                TextField(
                    "",
                    text: $input,
                    prompt: Text(verbatim: "discord.gg/hTKzmak")
                )
                .textFieldStyle(.plain)
                .font(.system(.body))
                .foregroundStyle(Ink.primary)
                .focused($isFieldFocused)
                // Return joins, which is what the capture's own flow did — the
                // reader typed the code and pressed Enter.
                .onSubmit { if state.canJoin { join() } }

                if state.isLooking {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                        .accessibilityLabel("Looking up that invite")
                }
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.control + Spacing.snug)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .strokeBorder(
                        isFieldFocused ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.quaternary),
                        lineWidth: 1
                    )
            }
            .animation(motion.fadeQuick, value: isFieldFocused)
            .accessibilityLabel("Invite link")

            // The three shapes the field accepts, stated rather than described.
            // `InvitePreview.code(in:)` really does take all three, and a
            // placeholder can only show one of them.
            if state.preview == nil {
                Text(verbatim: "hTKzmak · discord.gg/hTKzmak · discord.com/invite/hTKzmak")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Spacing.group)
    }

    @ViewBuilder
    private var preview: some View {
        if let preview = state.preview {
            InviteCard(preview: preview)
                .padding(.horizontal, Spacing.group)
                .padding(.top, Spacing.margin)
                .transition(.materialize)
        } else if let message = state.failureMessage {
            HStack(alignment: .top, spacing: Spacing.base) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(.caption))
                    .foregroundStyle(Palette.destructive)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.snug)
            .background(
                Palette.destructive.opacity(0.12),
                in: .rect(cornerRadius: Radius.chip, style: .continuous)
            )
            .padding(.horizontal, Spacing.group)
            .padding(.top, Spacing.margin)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.base) {
            SurfaceQuietButton(title: "Cancel", systemImage: nil, action: dismiss)
            Spacer(minLength: Spacing.base)
            if state.isJoining {
                ProgressView().controlSize(.small)
            }
            SurfaceFilledButton(title: "Join Server", systemImage: nil, action: join)
                .disabled(!state.canJoin)
                .opacity(state.canJoin ? 1 : 0.45)
        }
        .padding(Spacing.group)
        .animation(motion.fadeQuick, value: state.canJoin)
    }
}

// MARK: - What is behind the code

/// The server an invite points at.
///
/// Everything on it comes from the resolve — there is no second request — which
/// is why it draws the counts and the tag and not, say, the channel list.
private struct InviteCard: View {
    var preview: InvitePreview

    private static let iconSide: CGFloat = 52
    private static let coverHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            identity
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.glass, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .strokeBorder(Ink.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    /// The banner, when there is one. A server without one draws no strip at
    /// all rather than an empty band — the card is still a card without it.
    @ViewBuilder
    private var cover: some View {
        if let coverURL = preview.coverURL(width: 460) {
            RemoteImage(url: coverURL, side: 460, bucket: .artwork) {
                Rectangle().fill(Palette.hoverFill)
            }
            .aspectRatio(contentMode: .fill)
            .frame(height: Self.coverHeight)
            .frame(maxWidth: .infinity)
            .clipped()
            .accessibilityHidden(true)
        }
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            RemoteImage(url: preview.iconURL(side: Self.iconSide), side: Self.iconSide) {
                Text(preview.monogram)
                    .font(.system(size: Self.iconSide * 0.34, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: Self.iconSide, height: Self.iconSide)
                    .background(Palette.surface)
            }
            .frame(width: Self.iconSide, height: Self.iconSide)
            .clipShape(.rect(cornerRadius: Self.iconSide * 0.3, style: .continuous))

            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.tight) {
                    Text(preview.name)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                    if preview.isVerified || preview.isPartnered {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(.caption))
                            .foregroundStyle(Palette.affirmative)
                            .accessibilityLabel(preview.isVerified ? "Verified" : "Partnered")
                    }
                }

                counts

                if let description = preview.description {
                    Text(description)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.snug)
    }

    /// "48,014 online · 235,334 members", with a live dot.
    ///
    /// **Both are approximations and neither is labelled as one**, which is
    /// Discord's own choice: the field is `approximate_presence_count` and the
    /// number is drawn plain everywhere it appears. A count nobody has is left
    /// out rather than drawn as zero.
    @ViewBuilder
    private var counts: some View {
        if preview.onlineCount != nil || preview.memberCount != nil {
            HStack(spacing: Spacing.base) {
                if let online = preview.onlineCount {
                    Label {
                        Text("\(online, format: .number) online")
                    } icon: {
                        Circle()
                            .fill(Palette.presenceOnline)
                            .frame(width: 7, height: 7)
                    }
                }
                if let members = preview.memberCount {
                    Label {
                        Text("\(members, format: .number) members")
                    } icon: {
                        Circle()
                            .fill(Ink.quaternary)
                            .frame(width: 7, height: 7)
                    }
                }
            }
            .font(.system(.caption))
            .foregroundStyle(Ink.secondary)
            .labelStyle(.titleAndIcon)
        }
    }
}
