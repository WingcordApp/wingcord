import SwiftUI
import WingcordCore

/// Which Add App sheet the reader asked for.
///
/// **The choice comes first and the fetch follows it.** The two forms are
/// different requests — a user install asks for `applications.commands`, a
/// server install asks for `applications.commands bot` and answers with
/// ninety-five servers — so the picker cannot be a tab inside one sheet without
/// fetching both up front.
struct ApplicationInstallRequest: Hashable, Sendable, Identifiable {
    var applicationID: ApplicationID
    var name: String
    var iconHash: String?
    var summary: String
    /// Nil until the reader has chosen where.
    var integrationType: IntegrationType?

    var id: ApplicationID { applicationID }
}

/// "Add App" — where, then what it will be allowed to do, then the grant.
///
/// **This is the one surface in the app that gives something away**, so it is
/// built to be read rather than dismissed: the scopes are named in the
/// developer's terms, the permissions are listed in full, and the control that
/// commits says what it does. Discord's own sheet is three screens; this is one
/// that grows, because a 388-point popover with a back stack is a maze.
struct AddApplicationSheet: View {
    var request: ApplicationInstallRequest
    /// The channel the reader is in. `location_context` names it — see
    /// `installApplication`.
    var channelID: ChannelID
    var onFinished: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @Environment(\.dismiss) private var dismiss

    @State private var integrationType: IntegrationType?
    @State private var selectedGuildID: GuildID?
    @State private var isInstalling = false
    @State private var didInstall = false

    static let width: CGFloat = 380

    var body: some View {
        VStack(spacing: Spacing.snug) {
            header
            if didInstall {
                done
            } else if let integrationType {
                form(integrationType)
            } else {
                destinations
            }
        }
        .padding(Spacing.margin)
        .frame(width: Self.width)
        .animation(motion.panel, value: integrationType)
        .animation(motion.panel, value: didInstall)
        .animation(motion.panel, value: model.applicationInstall)
    }

    // MARK: The head

    private var header: some View {
        VStack(spacing: Spacing.base) {
            navigation
            ApplicationMark(
                url: request.iconHash.flatMap {
                    CDN.applicationIcon(id: request.applicationID, hash: $0, side: 56)
                },
                monogram: String(request.name.prefix(1)).uppercased(),
                side: 56
            )
            Text(request.name)
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(Ink.primary)
            if !request.summary.isEmpty {
                Text(request.summary)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// **One control, not two.** On the first screen there is nowhere to go
    /// back to, so the arrow closes the sheet; once a destination is chosen it
    /// returns to that choice. `INVARIANTS.md` §5.5 — a control that changes
    /// what it does is one control, and two rows that can both be offered is how
    /// a reader ends up with a Back that does nothing.
    private var navigation: some View {
        HStack(spacing: 0) {
            Button {
                if didInstall || integrationType == nil {
                    dismiss()
                } else {
                    goBack()
                }
            } label: {
                Image(systemName: integrationType == nil || didInstall
                    ? "xmark" : "chevron.backward")
                    .font(Typeface.controlGlyph)
                    .foregroundStyle(Ink.secondary)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(integrationType == nil || didInstall ? "Close" : "Back")
            Spacer(minLength: 0)
        }
    }

    private func goBack() {
        integrationType = nil
        model.applicationInstall = nil
        model.applicationInstallFailure = nil
    }

    // MARK: Where

    private var destinations: some View {
        VStack(spacing: Spacing.hair) {
            destination(
                .userInstall,
                title: "Add to My Apps",
                subtitle: "Use this app everywhere",
                systemImage: "person.crop.circle.badge.plus"
            )
            destination(
                .guildInstall,
                title: "Add to Server",
                subtitle: "Customize your server by adding this app",
                systemImage: "building.2.crop.circle"
            )
        }
    }

    private func destination(
        _ type: IntegrationType,
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        Button {
            integrationType = type
            Task { await model.sessionController.loadApplicationInstall(
                request.applicationID, integrationType: type
            ) }
        } label: {
            HStack(spacing: Spacing.snug) {
                Image(systemName: systemImage)
                    .font(.system(.title3))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    Text(subtitle)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(Ink.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(Spacing.snug)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: What it will be allowed to do

    @ViewBuilder
    private func form(_ type: IntegrationType) -> some View {
        if let failure = model.applicationInstallFailure {
            notice(failure, systemImage: "exclamationmark.triangle.fill", tint: Palette.destructive)
            backButton
        } else if let install = model.applicationInstall,
                  install.integrationType == type {
            if install.isAuthorized, type == .userInstall {
                notice("Already added to your apps", systemImage: "checkmark.circle.fill",
                       tint: Palette.affirmative)
                backButton
            } else {
                grant(install)
            }
        } else {
            ProgressView().controlSize(.small).padding(.vertical, Spacing.group)
        }
    }

    @ViewBuilder
    private func grant(_ install: ApplicationInstall) -> some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("This will allow \(install.name) to:")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)

            // The scopes, in words. **Named from the wire's own strings**: an
            // app that asks for something this client has no sentence for still
            // has it listed, spelled as Discord spells it, rather than silently
            // omitted from a consent screen.
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(install.parameters.scopes, id: \.self) { scope in
                    Label(Self.scopeLabel(scope), systemImage: "checkmark.circle.fill")
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.primary)
                }
            }

            if install.integrationType == .guildInstall {
                guildPicker(install)
                permissions(install)
            }

            policies(install)

            HStack(spacing: Spacing.base) {
                backButton
                Spacer(minLength: 0)
                authorizeButton(install)
            }
            .padding(.top, Spacing.tight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The servers the reader may add it to.
    ///
    /// **Only those they can.** The route answers ninety-five and the sheet
    /// offers the ones carrying `MANAGE_GUILD` — Discord's own words for the
    /// same rule are "This requires you to have Manage Server permission", and a
    /// list where nine in ten rows refuse is a list nobody reads.
    @ViewBuilder
    private func guildPicker(_ install: ApplicationInstall) -> some View {
        let guilds = install.installableGuilds
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("ADD TO SERVER")
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.tertiary)
            if guilds.isEmpty {
                Text("You do not manage any servers.")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.tertiary)
            } else {
                Picker("Server", selection: $selectedGuildID) {
                    ForEach(guilds) { guild in
                        Text(guild.name).tag(Optional(guild.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onAppear { selectedGuildID = selectedGuildID ?? guilds.first?.id }
            }
        }
        .padding(.top, Spacing.tight)
    }

    /// What the app is being granted in that server.
    ///
    /// **Listed, not editable**, and that is a limit rather than an oversight: a
    /// bitfield the reader trimmed is one the application may refuse to work
    /// under, and offering a checkbox that quietly breaks the app is worse than
    /// showing what it asked for and letting them decline the whole thing.
    @ViewBuilder
    private func permissions(_ install: ApplicationInstall) -> some View {
        let names = Self.permissionNames(install.parameters.permissions)
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("PERMISSIONS IT ASKS FOR")
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(Ink.tertiary)
                FlowLayout(spacing: Spacing.tight) {
                    ForEach(names, id: \.self) { name in
                        Text(name)
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(Ink.secondary)
                            .padding(.horizontal, Spacing.base)
                            .padding(.vertical, Spacing.tight)
                            .background(Palette.surfaceRaised, in: .capsule)
                    }
                }
            }
            .padding(.top, Spacing.tight)
        }
    }

    @ViewBuilder
    private func policies(_ install: ApplicationInstall) -> some View {
        if install.termsOfServiceURL != nil || install.privacyPolicyURL != nil {
            HStack(spacing: Spacing.base) {
                if let terms = install.termsOfServiceURL { Link("Terms", destination: terms) }
                if let privacy = install.privacyPolicyURL { Link("Privacy", destination: privacy) }
            }
            .font(Typeface.rowSubtitle)
            .tint(Palette.accent)
        }
    }

    // MARK: The controls

    private var backButton: some View {
        Button("Back", action: goBack)
            .buttonStyle(.plain)
            .font(.system(.subheadline))
            .foregroundStyle(Ink.secondary)
    }

    @ViewBuilder
    private func authorizeButton(_ install: ApplicationInstall) -> some View {
        let needsGuild = install.integrationType == .guildInstall
        Button {
            isInstalling = true
            Task {
                didInstall = await model.sessionController.installApplication(
                    install,
                    into: needsGuild ? selectedGuildID : nil,
                    from: channelID
                )
                isInstalling = false
            }
        } label: {
            Group {
                if isInstalling {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Authorize").font(.system(.subheadline, weight: .semibold))
                }
            }
            .frame(minWidth: 96)
            .frame(height: Metrics.control)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .emphasisChrome(Palette.accent)
        .disabled(isInstalling || (needsGuild && selectedGuildID == nil))
    }

    private var done: some View {
        VStack(spacing: Spacing.snug) {
            notice("Added", systemImage: "checkmark.circle.fill", tint: Palette.affirmative)
            Button("Done") {
                onFinished()
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 96)
            .frame(height: Metrics.control)
            .emphasisChrome(Palette.accent)
        }
    }

    private func notice(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(.subheadline))
            .foregroundStyle(Ink.secondary)
            .symbolRenderingMode(.palette)
            .foregroundStyle(Ink.secondary, tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Words for the wire's own strings

    /// Discord's scope names, in the sentences its own consent screen uses.
    ///
    /// An unrecognised scope is shown **verbatim** rather than dropped: this is
    /// a consent screen, and the one thing it must never do is hide something
    /// the reader is about to agree to.
    static func scopeLabel(_ scope: String) -> String {
        switch scope {
        case "applications.commands": "Create commands"
        case "bot": "Add a bot to this server"
        case "identify": "Access your username, avatar and banner"
        case "guilds": "Know what servers you are in"
        case "guilds.members.read": "Read your member profile in servers you share"
        case "rpc.activities.write": "Update your activity status"
        case "dm_channels.read": "See your direct message channels"
        case "email": "See your email address"
        default: scope
        }
    }

    /// The permissions in a bitfield, named.
    ///
    /// **Everything the app asked for, Administrator first.** OwO's bitfield
    /// carries it and Discord's own screen still lists the other eight beneath
    /// — which is the right way round for a consent screen: Administrator does
    /// subsume the rest, but hiding them would be hiding what is being granted.
    /// A name this client has no words for is dropped rather than shown as a bit
    /// number; the list is a summary and the bitfield is what is actually sent.
    static func permissionNames(_ permissions: Permissions) -> [String] {
        Self.namedPermissions
            .filter { permissions.contains($0.0) }
            .map(\.1)
    }

    private static let namedPermissions: [(Permissions, String)] = [
        (.administrator, "Administrator"),
        (.viewChannel, "View Channels"),
        (.sendMessages, "Send Messages"),
        (.sendMessagesInThreads, "Send Messages in Threads"),
        (.createPublicThreads, "Create Threads"),
        (.manageMessages, "Manage Messages"),
        (.manageThreads, "Manage Threads"),
        (.embedLinks, "Embed Links"),
        (.attachFiles, "Attach Files"),
        (.readMessageHistory, "Read Message History"),
        (.mentionEveryone, "Mention Everyone"),
        (.addReactions, "Add Reactions"),
        (.useExternalEmojis, "Use External Emoji"),
        (.useExternalStickers, "Use External Stickers"),
        (.useApplicationCommands, "Use Application Commands"),
        (.manageGuild, "Manage Server"),
        (.manageChannels, "Manage Channels"),
        (.manageRoles, "Manage Roles"),
        (.manageWebhooks, "Manage Webhooks"),
        (.manageNicknames, "Manage Nicknames"),
        (.manageExpressions, "Manage Expressions"),
        (.kickMembers, "Kick Members"),
        (.banMembers, "Ban Members"),
        (.moderateMembers, "Time Out Members"),
        (.createInvite, "Create Invite"),
        (.connect, "Connect to Voice"),
        (.speak, "Speak"),
        (.muteMembers, "Mute Members"),
        (.deafenMembers, "Deafen Members"),
        (.moveMembers, "Move Members"),
        (.viewAuditLog, "View Audit Log"),
    ]
}
