import AppKit
import Foundation
import WingcordCore
import WingcordNet

// MARK: - The local RPC server's host

extension SessionController {

    /// Opens Discord's local RPC server — once, for as long as an account is
    /// signed in: in the temporary folder games look in, and on the port a
    /// discord.com page tries first.
    func startLocalRPC() {
        guard localRPC == nil else { return }
        let server = LocalRPCServer(host: localRPCHost())
        localRPC = server
        server.start(directory: URL(filePath: NSTemporaryDirectory()), firstPort: LocalRPC.firstPort)
    }

    /// Closes every app's socket as signing out does — Discord's "User logged
    /// out" — and forgets what they were doing.
    func stopLocalRPC() {
        localRPC?.stop()
        localRPC = nil
        localRPCAssetNames = [:]
        localRPCAssetLinks = [:]
    }

    private func localRPCHost() -> LocalRPCServer.Host {
        LocalRPCServer.Host(
            currentUser: { [weak self] in self?.localRPCUser },
            application: { [rest] id in try await rest.rpcApplication(id) },
            resolveAssets: { [weak self] application, large, small in
                await self?.resolveLocalRPCAssets(application, [large, small]) ?? (nil, nil)
            },
            partyPrivacy: { [weak self] in
                guard let privacy = self?.model.activityPrivacy else { return (true, true) }
                return (privacy.allowsFriendsToJoin, privacy.allowsVoiceParticipantsToJoin)
            },
            setActivity: { [weak self] socket, activity in
                self?.model.setLocalRPCActivity(activity, socket: socket)
            },
            openInvite: { [weak self] (code: String) async throws(LocalRPC.CommandError) -> RPCValue in
                guard let self else { throw LocalRPC.CommandError(.invalidInvite, "Invalid invite id: \(code)") }
                return try await openInviteFromBrowser(code)
            },
            openDeepLink: { [weak self] type, params in
                self?.openLocalRPCDeepLink(type, params: params)
            }
        )
    }

    /// The reader as READY names them — `639621`.
    private var localRPCUser: RPCValue? {
        guard let id = model.currentUserID, let user = model.users[id] else { return nil }
        return LocalRPC.user(
            id: String(id.rawValue),
            username: user.username,
            discriminator: user.discriminator,
            globalName: user.displayName,
            avatar: user.avatarHash,
            bot: user.isBot,
            flags: Int(truncatingIfNeeded: user.flags.rawValue),
            premiumType: model.entitlements.premiumTier.rawValue
        )
    }

    /// Discord's `fetchAssetIds` (`970928`'s `RG`), by position: a link is
    /// turned into an `mp:` reference; a name is looked up among the app's
    /// pictures — asked for again once when it is not there, in case it was
    /// only just uploaded — and one that is still not there is nil.
    private func resolveLocalRPCAssets(_ application: ApplicationID, _ keys: [String?]) async -> (String?, String?) {
        let links = keys.compactMap { $0 }.filter { ($0.hasPrefix("http:") || $0.hasPrefix("https:")) && localRPCAssetLinks[$0] == nil }
        if !links.isEmpty {
            do {
                localRPCAssetLinks.merge(try await rest.externalAssetIDs(application: application, urls: links)) { _, new in new }
            } catch {
                Self.trace("rpc picture links refused: \(Self.describe(error))")
            }
        }
        let names = keys.compactMap { $0 }.filter { !$0.hasPrefix("http:") && !$0.hasPrefix("https:") }
        if !names.isEmpty, names.contains(where: { localRPCAssetNames[application]?[$0] == nil }) {
            do {
                localRPCAssetNames[application] = try await rest.applicationAssetIDs(application: application)
            } catch {
                Self.trace("rpc picture keys refused: \(Self.describe(error))")
            }
        }
        func resolved(_ key: String?) -> String? {
            guard let key else { return nil }
            return localRPCAssetLinks[key] ?? localRPCAssetNames[application]?[key]
        }
        return (resolved(keys.first ?? nil), resolved(keys.count > 1 ? keys[1] : nil))
    }

    /// INVITE_BROWSER — `43203`'s `$`: the invite, resolved and opened in
    /// the app's own join sheet, the window brought forward; or Discord's
    /// "Invalid invite id".
    private func openInviteFromBrowser(_ code: String) async throws(LocalRPC.CommandError) -> RPCValue {
        let lookup: InviteLookup
        do {
            lookup = try await rest.inviteCard(code)
        } catch {
            throw LocalRPC.CommandError(.invalidInvite, "Invalid invite id: \(code)")
        }
        guard case .resolved(let card) = lookup else {
            throw LocalRPC.CommandError(.invalidInvite, "Invalid invite id: \(code)")
        }
        NSApp.activate()
        model.inviteLookups[code] = lookup
        model.route(lookup, key: code)
        return .object([
            "code": .string(card.code),
            "guild": .object([
                "id": .string(card.guildID.map { String($0.rawValue) } ?? ""),
                "name": .string(card.name),
            ]),
        ])
    }

    /// DEEP_LINK: the window brought forward, and — for the two kinds this
    /// client has a place for — taken there: a channel or a message, or
    /// Settings. Discord's other kinds (its store, its changelog, its quests)
    /// have no page here, and bring the window forward only.
    private func openLocalRPCDeepLink(_ type: String, params: RPCValue?) {
        NSApp.activate()
        switch type {
        case "CHANNEL":
            guard let channel = params?["channelId"]?.string.flatMap(UInt64.init) else { return }
            let guild = params?["guildId"]?.string.flatMap(UInt64.init)
            model.openChannelLink(
                ChannelLink(
                    guildID: guild.map(GuildID.init(rawValue:)),
                    channelID: ChannelID(rawValue: channel),
                    messageID: params?["messageId"]?.string.flatMap(UInt64.init).map(MessageID.init(rawValue:))
                ),
                fallbackURL: nil
            )
        case "USER_SETTINGS":
            SettingsWindow.open()
        default:
            break
        }
    }
}
