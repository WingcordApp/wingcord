import CoreGraphics
import Foundation
import WingcordCore

/// Deterministic fixture data, behind `--demo`.
///
/// Not a "mock mode" the app can fall into by accident: nothing here runs unless
/// the flag is present, and there is no fallback from a failed sign-in to this.
/// A client that quietly shows fabricated servers when the network fails is one
/// nobody can trust.
///
/// It earns its place three times over — it is how the chrome is screenshotted
/// without an account, how the timeline is benchmarked against a known message
/// count, and how a layout regression is reproduced without waiting for a real
/// channel to look the same way twice.
enum DemoFixtures {

    /// Stands in for artwork on the one fixture with a derived theme. The CDN
    /// answers 404 for it, which is the honest outcome for a fabricated account
    /// and costs nothing: the palette is seeded, so nothing ever asks.
    private static let derivedAvatarHash = "demoderivedprofileavatar0000000f"

    /// The one nameplate path captured from a live account.
    ///
    /// Ends in a slash, as Discord sends it — `CDN.nameplate(asset:)` appends
    /// the file name rather than joining a path.
    private static let nameplateAsset = "nameplates/dark_roses/1526656194121568256/"

    /// Dark Roses (Blue), exactly as `GET /collectibles-products/{sku}` sent it.
    ///
    /// Seeded straight onto the store because `--demo` makes no requests: the
    /// artwork is fetched from the CDN like any other picture, but the payload
    /// that says *where to put it* would otherwise never arrive.
    private static let profileFrame: ProfileFrame? = {
        let sku = "1515124557290410204"
        let layers: [(String, ProfileFrame.Anchor)] = [
            ("1515124885113012234", .top),
            ("1515124888313266236", .bottom),
        ]
        let pieces = layers.compactMap { id, anchor in
            CDN.profileFrameLayer(sku: sku, layerID: id).map {
                ProfileFrame.Layer(id: id, url: $0, anchor: anchor, order: .front)
            }
        }
        guard !pieces.isEmpty else { return nil }
        return ProfileFrame(
            skuID: sku,
            label: "Blue roses sit on the top left and bottom right corners of "
                + "the profile and climb up the sides",
            innerWidth: 1200,
            overflowTop: 211,
            overflowBottom: 186,
            overflowHorizontal: 56,
            layers: pieces
        )
    }()

    static func populate(_ model: AppModel) {
        model.connectionState = .ready
        model.selfStatus = .online
        model.accountStanding = AccountStanding(state: .allGood)

        var users: [UserID: User] = [:]
        var userIDs: [UserID] = []
        for (offset, name) in names.enumerated() {
            // Real snowflake magnitudes, not 1…27. The default-avatar index is
            // `(id >> 22) % 6`, so small ids all resolve to the same picture and
            // a roster of fixtures looks wrong in a way real accounts never do.
            let id = UserID(rawValue: 900_000_000_000_000_000 + UInt64(offset) * 4_194_304)
            userIDs.append(id)
            users[id] = User(
                id: id,
                username: name.lowercased().replacing(" ", with: ""),
                displayName: name,
                discriminator: "0",
                isBot: offset % 11 == 0 && offset > 0
            )
        }
        // Collectibles on a handful of the roster.
        //
        // **Real assets, and for the reason the banner fixture already makes.**
        // A nameplate is fitted to the plate rect by arithmetic and a frame is
        // placed entirely by four numbers out of a payload; an arrangement like
        // that which has never been on screen without an account is one nobody
        // has checked. Both of these are public on the CDN — verified with an
        // unauthenticated request — so `--demo` draws the same pictures a real
        // session does.
        //
        // **One artwork across several palettes rather than several artworks.**
        // Only one nameplate asset has been captured, and inventing sibling
        // paths would 404 into a roster of empty plates. What varies is the
        // palette, which is what exercises the wash table.
        let palettes: [NameplatePalette] = [.cobalt, .crimson, .clover, .violet, .lemon]
        for (offset, id) in userIDs.enumerated() where offset % 5 == 2 {
            guard let user = users[id] else { continue }
            users[id] = User(
                id: user.id,
                username: user.username,
                displayName: user.displayName,
                avatarHash: user.avatarHash,
                discriminator: user.discriminator,
                flags: user.flags,
                isBot: user.isBot,
                isSystem: user.isSystem,
                decoration: UserDecoration(
                    nameplate: Nameplate(
                        asset: nameplateAsset,
                        palette: palettes[(offset / 5) % palettes.count],
                        label: "Blue roses with a butterfly."
                    ),
                    // Every other plated member also wears the frame, so a
                    // roster click reaches a card with one and a card without.
                    profileFrameSKU: offset % 10 == 2 ? profileFrame?.skuID : nil
                )
            )
        }
        if let profileFrame { model.profileFrames[profileFrame.skuID] = profileFrame }

        // Every effect and every face, spread across the roster, so `--demo`
        // reaches all seven and all twelve without an account that owns them.
        //
        // **The colours are the ones captured off Discord's own pickers**, not
        // invented. A palette Discord would never offer exercises the
        // derivation with values it never has to produce, which is how a wrong
        // multiplier survives a demo and fails on a real account.
        let effectColors: [DisplayNameEffect: [UInt32]] = [
            .solid: [0x58_65_F2],
            .gradient: [0x2A_AE_A6, 0xFF_C4_90],
            .neon: [0x99_65_F3],
            .toon: [0xF4_20_98],
            .pop: [0x23_A5_5A],
            .gummy: [0xEA_A9_D5, 0xA9_DD_F0, 0xB9_A7_EE, 0xB9_EA_CB],
            .prism: [0xFE_92_42, 0x35_ED_7E, 0xFF_E0_47, 0xFF_4C_D2, 0x58_65_F2],
        ]
        let effects = DisplayNameEffect.allCases
        let faces = DisplayNameFont.allCases
        for (offset, id) in userIDs.enumerated() where offset % 3 == 1 {
            guard let user = users[id] else { continue }
            let existing = user.decoration
            let slot = offset / 3
            let effect = effects[slot % effects.count]
            users[id] = User(
                id: user.id,
                username: user.username,
                displayName: user.displayName,
                avatarHash: user.avatarHash,
                discriminator: user.discriminator,
                flags: user.flags,
                isBot: user.isBot,
                isSystem: user.isSystem,
                decoration: UserDecoration(
                    // Kept, so a plated row can also carry a styled name and the
                    // two are seen together rather than one at a time.
                    nameplate: existing?.nameplate,
                    displayNameStyle: DisplayNameStyle(
                        font: faces[slot % faces.count],
                        effect: effect,
                        colors: effectColors[effect] ?? []
                    ),
                    profileFrameSKU: existing?.profileFrameSKU
                )
            )
        }


        let me = userIDs[0]
        users[me] = users[me].map { user in
            User(
                id: user.id,
                username: user.username,
                displayName: user.displayName,
                discriminator: user.discriminator,
                isBot: false,
                decoration: UserDecoration(
                    nameplate: Nameplate(
                        asset: nameplateAsset, palette: .cobalt,
                        label: "Blue roses with a butterfly."
                    ),
                    // The reader's own name is the one seen most often, so it
                    // wears the effect with the most moving parts.
                    displayNameStyle: DisplayNameStyle(
                        font: .tempo,
                        effect: .gummy,
                        colors: [0xEA_A9_D5, 0xA9_DD_F0, 0xB9_A7_EE, 0xB9_EA_CB]
                    ),
                    bio: "sometimes dev sometimes music, sometimes wasting time "
                        + "playing games\n\nPrimarily Swift and C++",
                    // A themed profile, so `--demo` exercises the coloured
                    // ground and not only the neutral one. These are the pair a
                    // real derived theme produced — the quantiser's own answer
                    // for a grey-and-taupe avatar — rather than a colour picked
                    // to look good, so what is on screen is what the algorithm
                    // actually yields.
                    // The reader wears one too, so the card the now bar opens
                    // is the framed case rather than the bare one.
                    profileFrameSKU: profileFrame?.skuID
                )
            )
        }
        model.currentUserID = me
        model.mentionableIDs = [me.rawValue]

        // A profile with a theme it CHOSE, so all three grounds are reachable
        // in `--demo`: neutral on most of the roster, chosen here, derived
        // below. The three are drawn differently and only the last two share a
        // code path.
        let chosenID = userIDs[6]
        if let user = users[chosenID] {
            users[chosenID] = User(
                id: user.id,
                username: user.username,
                displayName: user.displayName,
                avatarHash: user.avatarHash,
                discriminator: user.discriminator,
                isBot: false,
                decoration: UserDecoration(
                    themeColorValues: [0x46_1F_63, 0x7A_2A_5C],
                    premiumTier: .nitro
                )
            )
        }

        // One profile themed the OTHER way, so `--demo` shows both grounds.
        //
        // A chosen theme is a pair somebody picked; a derived one is quantised
        // out of their artwork and drawn differently — see `ProfileGround`. The
        // palette is seeded rather than extracted because a fixture avatar has
        // no artwork behind it, and seeding is also what keeps the guard in
        // `deriveTheme` from ever reaching the network for one. The values are
        // a real derived pair, measured from a live account.
        let derivedID = userIDs[0]
        if let user = users[derivedID] {
            users[derivedID] = User(
                id: user.id,
                username: user.username,
                displayName: user.displayName,
                avatarHash: derivedAvatarHash,
                discriminator: user.discriminator,
                isBot: false,
                // Merged, not replaced: this fixture is about the ground the
                // card is painted on, and dropping the bio, the nameplate and
                // the frame to demonstrate it would take three other things off
                // the one card that shows them.
                decoration: UserDecoration(
                    nameplate: user.decoration?.nameplate,
                    displayNameStyle: user.decoration?.displayNameStyle,
                    bio: user.decoration?.bio,
                    profileFrameSKU: user.decoration?.profileFrameSKU,
                    premiumTier: .nitro
                )
            )
            if let url = CDN.avatar(
                userID: derivedID, hash: derivedAvatarHash,
                side: CGFloat(ProfileThemePalette.pixelSize) / 2
            ) {
                model.derivedPalettes[url] = [0xC9_9C_8A, 0x2B_35_39]
            }
        }
        // **A bio that cannot be broken at a space**, because that is the whole
        // of a defect that survived several sessions: `ProseSegment` splits on
        // spaces and nothing else, so a long URL or a sentence of Chinese
        // reaches the flow layout as one segment six hundred points wide. The
        // layout used to report that upward and the card was then placed around
        // a box it did not have — drifting left, with a blank strip down its
        // right-hand side. A branch nothing on screen exercises is a branch that
        // breaks silently, so one fixture profile carries both shapes.
        let unbreakableID = userIDs[3]
        if let user = users[unbreakableID] {
            users[unbreakableID] = User(
                id: user.id,
                username: user.username,
                displayName: user.displayName,
                avatarHash: user.avatarHash,
                discriminator: user.discriminator,
                isBot: false,
                decoration: UserDecoration(
                    bio: "trades here: "
                        + "https://steamcommunity.com/tradeoffer/new/?partner=1249542580&token=aBcDeFgH\n"
                        + "\u{4EBA}\u{8A00}\u{53EF}\u{754F}\u{FF0C}\u{4F17}\u{53E3}\u{94C4}\u{91D1}\u{3002}"
                        + "\u{4EBA}\u{8A00}\u{53EF}\u{754F}\u{FF0C}\u{4F17}\u{53E3}\u{94C4}\u{91D1}\u{3002}",
                    connectedAccounts: [
                        // One with a page and one without, so both halves of the
                        // chip's affordance are on screen.
                        ConnectedAccount(
                            id: "76561198000000000", service: "steam",
                            name: "wingcord", isVerified: true
                        ),
                        ConnectedAccount(
                            id: "1", service: "playstation",
                            name: "wingcord_psn", isVerified: true
                        ),
                    ]
                )
            )
        }
        model.users = users

        var guilds: [GuildID: Guild] = [:]
        var folders: [GuildFolder] = []
        var index = ChannelIndex()

        for (offset, spec) in guildSpecs.enumerated() {
            let guildID = GuildID(rawValue: UInt64(1000 + offset))
            guilds[guildID] = Guild(
                id: guildID,
                name: spec.name,
                // A hash, so `SidebarHeader.hasBanner` is true and the banner
                // layout is actually exercised — the flag above used to set
                // nothing but the boost tier, so `--demo` never drew a banner
                // at all and the one arrangement in the chrome with real
                // arithmetic behind it could not be screenshotted without an
                // account. The CDN answers 404 for it, which is the honest
                // outcome for a fabricated guild and leaves the block showing
                // its loading ground: a flat rectangle with measurable edges.
                bannerHash: spec.hasBanner ? "demofixturebanner" : nil,
                ownerID: userIDs[0],
                premiumTier: spec.hasBanner ? 2 : 0,
                features: spec.isCommunity ? ["COMMUNITY"] : [],
                memberCount: spec.memberCount
            )
            index.replaceChannels(
                channels(for: guildID, spec: spec),
                inGuild: guildID
            )
            folders.append(GuildFolder(guildIDs: [guildID]))
        }

        // One real folder, to exercise the grouped path.
        let folderGuilds = Array(guilds.keys.sorted { $0.rawValue < $1.rawValue }.prefix(3))
        folders = [GuildFolder(
            id: 90_001,
            name: "Development",
            colorValue: 0x5865F2,
            guildIDs: folderGuilds
        )] + folders.filter { folder in
            !folder.guildIDs.contains { folderGuilds.contains($0) }
        }

        // Roles, members and presences for the first guild, so the roster
        // canvas — hoist groups, role colours, presence dots, activity lines —
        // is exercised rather than merely present.
        let firstGuild = GuildID(rawValue: 1000)
        let everyoneRole = RoleID(rawValue: firstGuild.rawValue)
        var guildRoles: [RoleID: Role] = [
            everyoneRole: Role(
                id: everyoneRole,
                name: "@everyone",
                position: 0,
                permissions: [.viewChannel, .sendMessages, .readMessageHistory, .addReactions]
            )
        ]
        for (offset, spec) in roleSpecs.enumerated() {
            let id = RoleID(rawValue: 2000 + UInt64(offset))
            guildRoles[id] = Role(
                id: id,
                name: spec.name,
                colorValue: spec.color,
                isHoisted: spec.hoisted,
                position: roleSpecs.count - offset
            )
        }
        model.roles[firstGuild] = guildRoles

        var guildMembers: [UserID: Member] = [:]
        var presences: [UserID: Presence] = [:]
        let hoistIDs = roleSpecs.indices.map { RoleID(rawValue: 2000 + UInt64($0)) }
        for (offset, userID) in userIDs.enumerated() {
            var roleIDs: [RoleID] = []
            if offset < hoistIDs.count { roleIDs.append(hoistIDs[offset]) }
            guildMembers[userID] = Member(
                userID: userID,
                roleIDs: roleIDs,
                joinedAt: Date.now.addingTimeInterval(-Double(offset) * 86_400 * 30)
            )
            let statuses: [PresenceStatus] = [.online, .idle, .doNotDisturb, .online, .offline]
            let status = statuses[offset % statuses.count]
            let activity: Activity? = offset % 4 == 1
                ? Activity(kind: .playing, name: "Xcode")
                : (offset % 7 == 3
                    ? Activity(kind: .custom, name: "Custom Status", state: "shipping it")
                    : nil)
            presences[userID] = Presence(
                userID: userID,
                status: status,
                isOnMobile: offset % 9 == 4,
                activities: activity.map { PresenceActivities(list: [$0]) }
            )
        }
        // The reader holds two of the named roles and has written a bio, so the
        // profile aside on Channels & Roles has something to draw. Without them
        // that card can only be looked at empty, which is the half of it least
        // worth checking.
        guildMembers[me] = Member(
            userID: me,
            nickname: nil,
            roleIDs: [hoistIDs[0], hoistIDs[3]],
            joinedAt: Date.now.addingTimeInterval(-86_400 * 420)
        )
        model.members[firstGuild] = guildMembers
        model.presences = presences

        model.guilds = guilds
        model.folders = folders
        model.channelIndex = index
        model.roleRevision &+= 1
        model.memberRevision &+= 1
        model.presenceRevision &+= 1
        model.railRevision &+= 1
        model.sidebarRevision &+= 1

        // Unread state on a few channels, so the badges and the bolding are
        // visible rather than theoretical.
        var readStates: [ChannelID: ReadState] = [:]
        for (offset, channelID) in index.channelIDs(inGuild: GuildID(rawValue: 1000)).enumerated() {
            guard index[channelID]?.kind.isConversation == true else { continue }
            readStates[channelID] = ReadState(
                lastAcknowledgedID: offset % 3 == 0 ? nil : MessageID(rawValue: .max),
                mentionCount: offset % 5 == 0 ? offset % 7 + 1 : 0,
                isMuted: false
            )
        }
        model.readStates = readStates

        let first = firstGuild
        model.selectedGuildID = first
        model.selectedChannelID = index.channelIDs(inGuild: first).first {
            index[$0]?.kind == .text
        }

        if let channelID = model.selectedChannelID {
            model.setMessages(transcript(in: channelID, users: users), in: channelID)
        }

        // **The guide's first resource gets a transcript too**, so the preview
        // column beside the guide has something in it. Without one the only
        // thing that surface can be looked at showing is its failure state,
        // which is the half of it least worth checking.
        let resourceChannelID = index.channelIDs(inGuild: first)
            .filter { index[$0]?.kind.isConversation == true }
            .dropFirst(2)
            .first
        if let resourceChannelID {
            model.setMessages(transcript(in: resourceChannelID, users: users), in: resourceChannelID)
        }

        // The guide's welcome is written by the owner, and the crown beside it
        // says so — which is only true if the fixture's owner IS that person.
        let guideAuthor = userIDs[1]
        model.guilds[firstGuild]?.ownerID = guideAuthor
        populateGuildSurfaces(model, guildRoles: guildRoles, owner: guideAuthor)
        populateConnectedApps(model)
        // **The guild that actually HAS a voice channel, not the first one.**
        // This passed `first` and guarded on finding a voice channel in it, so
        // when no fixture guild but the last one had a `lobby`, the guard took
        // the early return and the demo has never once shown a call. That is
        // why `HANDOFF.md` §0.3 says nobody has ever looked at the encryption
        // indicator: `--demo` could not draw the surface it lives on.
        let voiceGuildID = model.guilds.keys.first { guildID in
            index.channelIDs(inGuild: guildID).contains { index[$0]?.kind == .voice }
        }
        populateVoice(
            model, index: index, guildID: voiceGuildID ?? first, me: me, others: userIDs
        )
    }

    // MARK: A call in progress
    //
    // **A demo launch has no socket, so a call has to be assembled by hand or
    // the whole surface can only ever be looked at empty.** Everything below is
    // a fact a real session receives as a `VOICE_STATE_UPDATE`: the same shape,
    // written straight into the same table.
    //
    // The reader is put IN the call rather than beside it, because the two
    // states of that pane — the room seen from outside and the room you are in —
    // are one click apart and the second is the one with every piece of the
    // layout in it: the grid, the pills, the marks, the control cluster, the
    // HUD in the sidebar.
    private static func populateVoice(
        _ model: AppModel,
        index: ChannelIndex,
        guildID: GuildID,
        me: UserID,
        others: [UserID]
    ) {
        guard let voiceChannelID = index.channelIDs(inGuild: guildID).first(where: {
            index[$0]?.kind == .voice
        }) else { return }

        var states: [UserID: VoiceState] = [:]
        states[me] = VoiceState(
            userID: me,
            channelID: voiceChannelID,
            guildID: guildID,
            sessionID: "demo"
        )
        // Four other people, each in a different state, so every mark on a tile
        // is on screen at once: somebody talking, somebody muted, somebody
        // deafened, and somebody sharing a screen.
        let cast: [(UserID, Bool, Bool, Bool)] = zip(
            others.filter { $0 != me }.prefix(4),
            [(false, false, false), (true, false, false), (true, true, false), (false, false, true)]
        ).map { ($0, $1.0, $1.1, $1.2) }

        for (userID, muted, deafened, streaming) in cast {
            states[userID] = VoiceState(
                userID: userID,
                channelID: voiceChannelID,
                guildID: guildID,
                sessionID: "demo",
                isSelfMuted: muted,
                isSelfDeafened: deafened,
                isStreaming: streaming
            )
        }
        model.voiceStates = states
        model.connectedVoiceChannelID = voiceChannelID
        model.isVoiceChatShown = true
        // Two people talking at once, which is what makes the speaking ring and
        // the tile's own lit edge visible together rather than one at a time.
        model.speakingUserIDs = Set(cast.prefix(1).map(\.0))
        model.voiceQuality = VoiceQuality(
            lossPercent: 0, jitterMilliseconds: 8, isConnected: true,
            // A real epoch authenticator's shape: thirty digits, which is what
            // the call's shield reads out when somebody asks what it protects.
            encryption: .endToEnd(verificationCode: "090606058512110636351516066685")
        )
        model.voiceRevision &+= 1

        // Discord's own six, verbatim from `GET /soundboard-default-sounds`, so
        // the picker's free half is real rather than invented.
        model.defaultSoundboardSounds = [
            SoundboardSound(id: "1", name: "quack", emojiName: "🦆"),
            SoundboardSound(id: "2", name: "airhorn", emojiName: "🔊"),
            SoundboardSound(id: "3", name: "cricket", emojiName: "🦗"),
            SoundboardSound(id: "4", name: "golf clap", emojiName: "👏"),
            SoundboardSound(id: "5", name: "sad horn", emojiName: "🎺"),
            SoundboardSound(id: "7", name: "ba dum tss", emojiName: "🥁"),
        ]
        // A server's own set, which is the half behind the gate — and the demo
        // account carries no Nitro, so the picker draws it locked.
        model.guildSoundboardSounds[guildID] = [
            SoundboardSound(id: "1000", name: "bonk", emojiName: "🔨", guildID: guildID),
            SoundboardSound(id: "1001", name: "fire in the hole", emojiName: "💣", guildID: guildID),
            SoundboardSound(id: "1002", name: "wow", emojiName: "😮", guildID: guildID),
            SoundboardSound(id: "1003", name: "nice", emojiName: "😎", guildID: guildID),
        ]
        model.soundboardRevision &+= 1
    }

    // MARK: The server's own pages
    //
    // Server Guide, Channels & Roles and Game Servers. Fixtures for all three,
    // because each is gated on its route having ANSWERED — a demo launch has no
    // socket, so without these the three rows would never appear at all and the
    // one arrangement in the chrome with real arithmetic behind it could not be
    // looked at without an account.
    //
    // Two servers, deliberately different: the first has everything, and the
    // third has a guide and no questions — which is the case that decides
    // whether the sidebar row says "Channels & Roles" or "Browse Channels".

    private static func populateGuildSurfaces(
        _ model: AppModel,
        guildRoles: [RoleID: Role],
        owner: UserID
    ) {
        let first = GuildID(rawValue: 1000)
        let third = GuildID(rawValue: 1002)
        let channels = model.channelIndex.channelIDs(inGuild: first).filter {
            model.channelIndex[$0]?.kind.isConversation == true
        }
        guard channels.count >= 6 else { return }

        model.serverGuides[first] = ServerGuide(
            guildID: first,
            isEnabled: true,
            welcome: ServerGuide.Welcome(
                authorIDs: [owner],
                message: "Welcome to The Iris Project [@username]! This is where the "
                    + "releases land and where everything gets argued about first. "
                    + "Here is what to do while you are getting your bearings;"
            ),
            actions: [
                ServerGuide.Action(
                    id: 0,
                    channelID: channels[0],
                    kind: .read,
                    title: "Read what this place is",
                    emojiName: "wave"
                ),
                ServerGuide.Action(
                    id: 1,
                    channelID: channels[3],
                    kind: .read,
                    title: "See what shipped this month",
                    emojiName: "sparkles"
                ),
                ServerGuide.Action(
                    id: 2,
                    channelID: channels[5],
                    kind: .write,
                    title: "Come say hello",
                    emojiName: "speech_balloon"
                ),
            ],
            resources: [
                ServerGuide.Resource(
                    id: 0,
                    channelID: channels[2],
                    title: "Rules & Roles",
                    detail: "Pick roles here and read up on our guidelines"
                ),
                ServerGuide.Resource(
                    id: 1,
                    channelID: channels[1],
                    title: "Frequently asked",
                    detail: "The questions that come up every single week"
                ),
            ]
        )

        // A guide with no questions behind it, so the row that says "Browse
        // Channels" is on screen somewhere too — and one action, so the guide
        // has a row at all and its rules gate can be reached.
        let thirdChannels = model.channelIndex.channelIDs(inGuild: third).filter {
            model.channelIndex[$0]?.kind.isConversation == true
        }
        model.serverGuides[third] = ServerGuide(
            guildID: third,
            isEnabled: true,
            welcome: nil,
            actions: thirdChannels.first.map {
                [ServerGuide.Action(id: 0, channelID: $0, kind: .read, title: "Start here")]
            } ?? [],
            resources: []
        )

        // The named roles only. `@everyone` is granted by joining, not by
        // answering a question, and an option that claims to grant it is a
        // sentence that is simply false.
        let colouredRoles = guildRoles.values
            .filter { $0.name != "@everyone" }
            .sorted { $0.position > $1.position }
            .map(\.id)
        model.guildOnboardings[first] = GuildOnboarding(
            guildID: first,
            isEnabled: true,
            prompts: [
                GuildOnboarding.Prompt(
                    id: 5001,
                    title: "Where in the world are you?",
                    options: [
                        onboardingOption(1, "Europe", "earth_africa", colouredRoles, 0, channels),
                        onboardingOption(2, "North America", "earth_americas", colouredRoles, 1, channels),
                        onboardingOption(3, "Asia", "earth_asia", colouredRoles, 2, channels),
                        onboardingOption(4, "Oceania", "ocean", colouredRoles, 3, channels),
                    ],
                    isSingleSelect: false,
                    isRequired: true
                ),
                GuildOnboarding.Prompt(
                    id: 5002,
                    title: "What should we ping you about?",
                    options: [
                        onboardingOption(5, "Releases", "rocket", colouredRoles, 4, channels),
                        onboardingOption(6, "Community events", "trophy", colouredRoles, 5, []),
                        onboardingOption(7, "Nothing at all", "sleeping", [], 0, []),
                    ],
                    isSingleSelect: false,
                    isRequired: false
                ),
            ],
            defaultChannelIDs: Array(channels.prefix(4)),
            responses: [1, 5]
        )

        var counts: [RoleID: Int] = [:]
        for (offset, roleID) in colouredRoles.enumerated() {
            counts[roleID] = [186_202, 76_308, 58_495, 12_407, 101_061, 2_768][offset % 6]
        }
        model.roleMemberCounts[first] = counts

        // **Three follow states, because the browse page draws three**: a
        // channel the reader chose, one they did not, and one whose tick belongs
        // to the category above it and cannot be pressed. A fixture where
        // everything is followed can only be looked at in one of them — and the
        // channel list beside it filters on the same answer, so the two would
        // agree vacuously.
        //
        // The first category is followed and carries its channels; the rest are
        // not, and their channels answer for themselves. The last two channels
        // in the server are followed by nobody, which is what takes them out of
        // the sidebar.
        let allChannels = model.channelIndex.channelIDs(inGuild: first)
        let categories = allChannels.filter { model.channelIndex[$0]?.kind == .category }
        var followed = Set(allChannels.filter { model.channelIndex[$0]?.kind != .category })
        followed.subtract(allChannels.suffix(2))
        if let carried = categories.first {
            for channelID in allChannels
            where model.channelIndex[channelID]?.parentID == carried {
                followed.remove(channelID)
            }
            followed.insert(carried)
        }
        model.followedChannelIDs = followed

        model.memberVerifications[first] = MemberVerification(
            guildID: first,
            detail: "Welcome to the most argued-about release channel on Discord.",
            rules: [
                "Be friendly, treat everyone with respect. No harassment, toxicity, "
                    + "witch hunting, sexism, racism, or hate speech will be tolerated.",
                "No spam or self-promotion — server invites, advertisements and the "
                    + "rest. That includes DMing fellow members.",
                "No NSFW, obscene, or discriminatory content.",
                "Communicate in the text channels using English.",
                "Do not ask for free stuff or attempt to scam anyone.",
                "If you see something against the rules, or something that makes you "
                    + "feel unsafe, let the staff know.",
            ]
        )

        // **A second community server where the reader has NOT agreed.** The
        // rules gate is a real state — join on a phone, never accept, open this
        // — and it is the only state in which the banner and the Agree button
        // exist at all, so without a fixture for it neither can be looked at.
        model.guilds[third]?.rulesChannelID = model.channelIndex
            .channelIDs(inGuild: third)
            .first { model.channelIndex[$0]?.name.contains("rules") == true }
        if let me = model.currentUserID {
            model.members[third] = [
                me: Member(userID: me, roleIDs: [], joinedAt: Date.now, isPending: true)
            ]
        }
        model.memberVerifications[third] = MemberVerification(
            guildID: third,
            detail: "A small server with three rules and no patience for a fourth.",
            rules: [
                "Be decent to each other.",
                "Keep it on topic in the numbered channels.",
                "No self-promotion without asking first.",
            ],
            version: "2020-12-28T20:15:57.529000+00:00",
            termsLabel: "Read and agree to the server rules"
        )

        model.gameServers[first] = [
            GameServer(
                id: 7_001,
                skuID: "demo-pro-plan",
                name: "Iris Test Server",
                status: .online,
                regionName: "France",
                planName: "Pro Plan",
                ip: "5.39.17.17",
                port: "25372",
                playersOnline: 4,
                maxPlayers: 16,
                gameName: "Counter-Strike 2",
                gameVersion: "latest",
                providerURL: URL(string: "https://example.invalid/server/demo")
            ),
            GameServer(
                id: 7_002,
                skuID: "demo-starter-plan",
                name: "Weekend Scrims",
                status: .offline,
                regionName: "Germany",
                planName: "Starter Plan",
                ip: "5.39.17.18",
                port: "27015",
                playersOnline: 0,
                maxPlayers: 10,
                gameName: "Counter-Strike 2",
                gameVersion: "latest",
                scheduledAction: "start",
                scheduledActionAt: Date.now.addingTimeInterval(3600 * 9)
            ),
        ]

        model.gameServerProducts["demo-pro-plan"] = GameServerProduct(
            skuID: "demo-pro-plan",
            instructions: [
                "In the Steam client, navigate to View > Game Servers.",
                "Click **Favorites**, then click the + button.",
                "Enter your server's IP & port then click **OK**.",
                "Select your server, then click **Connect**.",
            ]
        )
    }

    // MARK: Connected Apps

    /// Three linked accounts and three authorized apps — fictional, not the
    /// account this pane was built by reading a capture of. Real snowflakes
    /// again, spread out enough that "Authorized" reads as three different
    /// moments instead of three identical ones.
    private static func populateConnectedApps(_ model: AppModel) {
        func grantID(_ monthsAgo: UInt64) -> OAuthGrantID {
            OAuthGrantID(
                rawValue: (recentMilliseconds - monthsAgo * 2_592_000_000
                    - Snowflake<OAuthGrantTag>.epochMilliseconds) << 22
            )
        }
        func applicationID(_ seed: UInt64) -> ApplicationID {
            ApplicationID(rawValue: 700_000_000_000_000_000 + seed * 4_194_304)
        }

        model.connections = [
            AccountConnection(
                id: "demo-spotify-1", type: "spotify", name: "iris.tracklist",
                isVerified: true, showsActivity: true, isVisibleOnProfile: true,
                isFriendSyncEnabled: false, isRevoked: false
            ),
            AccountConnection(
                id: "demo-github-1", type: "github", name: "iris-dev",
                isVerified: true, showsActivity: false, isVisibleOnProfile: true,
                isFriendSyncEnabled: false, isRevoked: false
            ),
            AccountConnection(
                id: "demo-steam-1", type: "steam", name: "iris",
                isVerified: true, showsActivity: true, isVisibleOnProfile: false,
                isFriendSyncEnabled: false, isRevoked: false
            ),
        ]

        model.authorizedApps = [
            AuthorizedApp(
                id: grantID(1),
                applicationID: applicationID(1),
                name: "Watch Together",
                iconHash: nil,
                description: "Create and watch shared playlists of YouTube videos with your friends. Your choice to share the remote or not.",
                isVerified: true,
                scopes: ["identify", "guilds", "guilds.members.read", "applications.commands", "rpc.activities.write"],
                termsOfServiceURL: URL(string: "https://discord.com/terms"),
                privacyPolicyURL: URL(string: "https://discord.com/privacy")
            ),
            AuthorizedApp(
                id: grantID(5),
                applicationID: applicationID(2),
                name: "Poker Night",
                iconHash: nil,
                description: "A Texas hold 'em style card game with your server.",
                isVerified: true,
                scopes: ["identify", "applications.commands", "guilds.members.read", "rpc.voice.read"],
                termsOfServiceURL: nil,
                privacyPolicyURL: nil
            ),
            AuthorizedApp(
                id: grantID(14),
                applicationID: applicationID(3),
                name: "iris-dashboard.app",
                iconHash: nil,
                description: "",
                isVerified: false,
                scopes: ["identify", "email", "guilds"],
                termsOfServiceURL: nil,
                privacyPolicyURL: nil
            ),
        ]
    }

    private static func onboardingOption(
        _ id: UInt64,
        _ title: String,
        _ emoji: String,
        _ roles: [RoleID],
        _ roleIndex: Int,
        _ channels: [ChannelID]
    ) -> GuildOnboarding.Option {
        GuildOnboarding.Option(
            id: id,
            title: title,
            emojiName: emoji,
            roleIDs: roles.indices.contains(roleIndex) ? [roles[roleIndex]] : [],
            channelIDs: Array(channels.prefix(id % 3 == 0 ? 2 : 0))
        )
    }

    // MARK: Shapes

    private struct GuildSpec {
        var name: String
        var hasBanner: Bool
        var isCommunity: Bool
        var memberCount: Int
        var categories: [(String, [String])]
    }

    private static let guildSpecs: [GuildSpec] = [
        GuildSpec(
            name: "The Iris Project",
            hasBanner: true,
            isCommunity: true,
            memberCount: 12_400,
            categories: [
                ("THIS IS IRIS", ["this-is-iris", "faq", "rules"]),
                ("EVENTS", ["iris-releases", "community-news", "devlog", "sus"]),
                ("SUPPORT", ["voxy-screenshot-contest", "help", "bug-reports"]),
            ]
        ),
        GuildSpec(
            name: "Krxqz | Cfgs, Clients and more",
            hasBanner: false,
            isCommunity: false,
            memberCount: 8_120,
            categories: [
                ("LOBBY", ["announcement", "giveaways", "upload", "config-updates"]),
                ("MAIN", ["chat", "media", "anticheat-list", "mate-finder"]),
                ("CONFIGS AND CLIENTS", ["configs", "free-clients", "israeli-client"]),
            ]
        ),
        GuildSpec(
            name: "Wingcord",
            hasBanner: false,
            isCommunity: true,
            memberCount: 419,
            categories: [
                ("INFO", ["announcements", "rules-and-roles", "faq"]),
                ("CHAT", ["general", "referrals", "coding-help", "server-suggestions"]),
                ("DEV", ["suggestions", "bug-reporting"]),
                ("DEV WEBHOOKS", ["github-events", "etfkit-events"]),
            ]
        ),
        GuildSpec(name: "Flux", hasBanner: false, isCommunity: false, memberCount: 640,
                  categories: [("GENERAL", ["general", "off-topic"])]),
        GuildSpec(name: "Apple Devs", hasBanner: false, isCommunity: false, memberCount: 2_100,
                  categories: [("SWIFT", ["swiftui", "concurrency", "showcase"])]),
        GuildSpec(name: "Cosmic", hasBanner: false, isCommunity: false, memberCount: 88,
                  categories: [("HOME", ["lobby"])]),
    ]

    /// Now, in Discord's own units. Resolved once so every fixture channel is
    /// dated against the same instant.
    private static let recentMilliseconds = UInt64(Date.now.timeIntervalSince1970 * 1000)

    /// Topics, so the browse list's two-line rows are exercised. Deliberately
    /// uneven in length: a page whose every subtitle is the same width is a page
    /// that has never met a real server.
    private static let topics = [
        "Everything that ships, and the arguments before it does.",
        "",
        "Ask here before opening an issue — most of it is answered already.",
        "Screenshots, mockups and the occasional cursed render.",
        "",
        "Release notes land here automatically. Read-only.",
    ]

    private static func channels(for guildID: GuildID, spec: GuildSpec) -> [Channel] {
        var result: [Channel] = []
        var position = 0
        var serial: UInt64 = 0

        for (categoryName, channelNames) in spec.categories {
            serial += 1
            let categoryID = ChannelID(rawValue: guildID.rawValue * 1000 + serial)
            result.append(Channel(
                id: categoryID,
                kind: .category,
                guildID: guildID,
                name: categoryName,
                position: position
            ))
            position += 1

            for name in channelNames {
                serial += 1
                result.append(Channel(
                    id: ChannelID(rawValue: guildID.rawValue * 1000 + serial),
                    kind: name.contains("vc") || name == "lobby" ? .voice : .text,
                    guildID: guildID,
                    name: name,
                    topic: topics[Int(serial) % topics.count],
                    parentID: categoryID,
                    position: position,
                    // **A real snowflake, not a small integer.** The high 42
                    // bits are a millisecond timestamp, so `8_000_000` is
                    // January 2015 and every channel in the browse list reads
                    // "11 years ago" — which makes the one line on that page
                    // with real arithmetic behind it impossible to judge.
                    lastMessageID: MessageID(
                        rawValue: (recentMilliseconds - UInt64(serial) * 5_400_000
                            - Snowflake<MessageTag>.epochMilliseconds) << 22
                    )
                ))
                position += 1
            }
        }
        return result
    }

    /// A transcript with runs, day gaps, replies and a system event, so the
    /// reducer's every branch is visible on screen rather than only in a test.
    private static func transcript(in channelID: ChannelID, users: [UserID: User]) -> MessageBox {
        var box = MessageBox()
        var messages: [Message] = []
        let userIDs = users.keys.sorted { $0.rawValue < $1.rawValue }
        // Start two days back so the day separators have something to separate.
        var moment = Date.now.addingTimeInterval(-2 * 24 * 60 * 60)

        for index in 0..<220 {
            // Runs of two to four from one person, then a gap.
            let author = userIDs[(index / 3) % userIDs.count]
            moment.addTimeInterval(index % 3 == 0 ? 640 : 45)
            let milliseconds = UInt64(moment.timeIntervalSince1970 * 1000)
                - Snowflake<MessageTag>.epochMilliseconds
            let id = MessageID(rawValue: (milliseconds << 22) | UInt64(index + 1))
            let isSystem = index % 47 == 46
            // **A reply quotes a message that is actually above it.** A
            // reference to an id nothing owns draws the "deleted" strip, which
            // is a state worth seeing but not the one that exercises the header
            // — so one of the two is deliberate and the other points at a real
            // row four back.
            let reference = Self.reference(at: index, in: messages, users: users)
            messages.append(Message(
                id: id,
                channelID: channelID,
                authorID: author,
                content: content(at: index),
                kind: isSystem ? .userJoin : (reference == nil ? .default : .reply),
                // Two pins per channel, so the pane and the transcript's own
                // pin state have something to disagree about if they ever do.
                isPinned: index == 34 || index == 187,
                payload: Self.payload(
                    at: index,
                    reference: reference,
                    reactions: Self.reactions(at: index)
                )
            ))
        }

        box.messages = messages
        box.hasMoreHistory = true
        return box
    }

    /// What one fixture message says.
    ///
    /// **An emoji-only message every so often**, because the jumbo rule is a
    /// layout branch and a branch nothing on screen exercises is a branch that
    /// breaks silently.
    private static func content(at index: Int) -> String {
        switch index % 23 {
        case 7: "🎉"
        case 18: "😀 🎉 ✨"
        default: bodies[index % bodies.count]
        }
    }

    /// The rare parts of a message: an embed with a link button, and a sticker.
    ///
    /// Both are structures with real arithmetic behind them and neither can be
    /// seen without an account otherwise — which is exactly the gap `--demo`
    /// exists to close.
    /// Everything rare about one fixture message, folded into one box.
    ///
    /// The box is built only when there is something to put in it — a decoder
    /// that allocates one for every plain message has undone the point of the
    /// type, and the fixtures have to model that as faithfully as the wire does.
    private static func payload(
        at index: Int,
        reference: MessageReference?,
        reactions: [Reaction]
    ) -> MessagePayload? {
        let rare = payload(at: index)
        guard reference != nil || !reactions.isEmpty else { return rare }
        return MessagePayload(
            attachments: rare?.attachments ?? [],
            embeds: rare?.embeds ?? [],
            reactions: reactions,
            stickers: rare?.stickers ?? [],
            components: rare?.components ?? [],
            displayComponents: rare?.displayComponents ?? [],
            poll: rare?.poll,
            reference: reference
        )
    }

    /// What a reply at this index quotes.
    ///
    /// One in eleven, pointing four rows back — far enough that the target is a
    /// different author and the header has a face and a name that are not the
    /// replier's. One of them deliberately quotes nothing, which is the
    /// "original message was deleted" strip.
    private static func reference(
        at index: Int,
        in messages: [Message],
        users: [UserID: User]
    ) -> MessageReference? {
        guard index % 11 == 5, index >= 4 else { return nil }
        guard index != 60 else {
            // The one whose target is gone. A reference with no author is
            // exactly what Discord sends for a deleted message.
            return MessageReference(messageID: MessageID(rawValue: 1))
        }
        let target = messages[index - 4]
        return MessageReference(
            messageID: target.id,
            channelID: target.channelID,
            authorID: target.authorID,
            isAuthorBot: users[target.authorID]?.isBot ?? false,
            excerpt: MessageReference.excerpt(of: target.content),
            hasAttachment: !target.attachments.isEmpty
        )
    }

    /// The chips under a message.
    ///
    /// Three shapes, because they draw differently: one the reader has joined,
    /// one they have not, and a row of several so the wrap is exercised.
    private static func reactions(at index: Int) -> [Reaction] {
        switch index % 17 {
        case 4:
            [Reaction(emoji: EmojiRef(name: "👍"), count: 3, isMine: true)]
        case 9:
            [
                Reaction(emoji: EmojiRef(name: "🔥"), count: 12, isMine: false),
                Reaction(emoji: EmojiRef(name: "😀"), count: 2, isMine: false),
            ]
        case 13:
            [
                Reaction(emoji: EmojiRef(name: "✅"), count: 1, isMine: true),
                Reaction(emoji: EmojiRef(name: "🎉"), count: 8, isMine: false),
                Reaction(emoji: EmojiRef(name: "😢"), count: 4, isMine: false),
                Reaction(emoji: EmojiRef(name: "❤️"), count: 21, isMine: false),
            ]
        default:
            []
        }
    }

    private static func payload(at index: Int) -> MessagePayload? {
        switch index % 31 {
        case 12:
            MessagePayload(
                embeds: [Embed(
                    title: "Wingcord v0.4",
                    description: "**Highlights**\n- Embeds, components and system rows\n"
                        + "- Stickers in the transcript\n- `jumbo` emoji",
                    url: "https://example.com/release",
                    colorValue: 0x5865F2,
                    author: Embed.Author(name: "Releases"),
                    footer: Embed.Footer(text: "Nightly"),
                    fields: [
                        Embed.Field(name: "Build", value: "1204", isInline: true),
                        Embed.Field(name: "Channel", value: "nightly", isInline: true),
                    ]
                )],
                components: [ActionRow(components: [
                    MessageComponent(
                        id: "view",
                        label: "View release",
                        kind: .link("https://example.com/release"),
                        style: .link
                    ),
                    MessageComponent(id: "retry", label: "Refresh", kind: .action, style: .secondary),
                ])]
            )
        case 25:
            MessagePayload(stickers: [
                StickerRef(id: 749_054_660_769_218_631, name: "Wave", format: .png),
            ])
        case 8:
            // Three real files, so the lightbox has something to open — a
            // picture worth zooming into, a loop worth scrubbing and a clip
            // worth scrubbing differently. See `DemoMedia`.
            MessagePayload(attachments: DemoMedia.attachments())
        case 21:
            // And the same picture hidden, because reveal-then-open is a
            // two-press path that nothing else here exercises.
            DemoMedia.spoiler().map { MessagePayload(attachments: [$0]) }
        case 19:
            // A Components V2 body. It has no `content` and no embeds at all,
            // which is exactly the shape that used to draw an author line over
            // a blank row.
            MessagePayload(
                displayComponents: [
                    .container(accent: 0xEC_4899, children: [
                        .text("## Wingcord Roadmap"),
                    ]),
                    .container(accent: 0xEC_4899, children: [
                        .text("**v0.5 — Read everything**\nEmbeds and components\n"
                            + "Polls, stickers and system rows\nGroup conversations"),
                        .separator(isDivider: true, isLarge: false),
                        .text("-# Shipping when it is right"),
                    ]),
                    .row(ActionRow(components: [
                        MessageComponent(
                            id: "open",
                            label: "Open roadmap",
                            kind: .link("https://example.com/roadmap"),
                            style: .link
                        ),
                    ])),
                ]
            )
        case 3:
            MessagePayload(poll: Poll(
                question: "Should the nightly build ship broken features?",
                answers: [
                    Poll.Answer(
                        id: 1,
                        text: "Yes, let them break",
                        emoji: EmojiRef(name: "🔥"),
                        count: 10,
                        isMine: true
                    ),
                    Poll.Answer(
                        id: 2,
                        text: "No, keep them polished",
                        emoji: EmojiRef(name: "❌"),
                        count: 2
                    ),
                ],
                isFinalized: true
            ))
        default:
            nil
        }
    }

    private struct RoleSpec {
        var name: String
        var color: UInt32
        var hoisted: Bool
    }

    private static let roleSpecs: [RoleSpec] = [
        RoleSpec(name: "Main Dev", color: 0xE67E22, hoisted: true),
        RoleSpec(name: "Admin", color: 0xE91E63, hoisted: true),
        RoleSpec(name: "Contributor", color: 0x2ECC71, hoisted: true),
        RoleSpec(name: "Server Booster", color: 0xF47FFF, hoisted: true),
        RoleSpec(name: "Bots", color: 0x5865F2, hoisted: true),
    ]

    private static let names = [
        "alex", "Blåhaj", "Hellomarlo", "Bram", "iamnumber7", "MarvelMallow",
        "rin", "pip", "Voltcast", "Jay", "0xC0FFEE42", "2lumin0s", "vale",
        "Void", "torriel", "vexlor", "alegre", "Toffee", "Ceruleanate", "Dyno",
        "NQN", "kazume", "Quelix", "vrm", "million", "beagle", "jamesen",
    ]

    private static let bodies = [
        "the sidebar column is painted with nothing — the system backs it",
        "that is what stops macOS re-resolving the column widths",
        "the desktop and the menu-bar accent come through for free",
        "the detail is one view type; what to show is a parameter",
        "**bold**, *italic*, `code`, and ||a spoiler|| all in one line",
        "https://example.com and a [masked link](https://example.com)",
        "one canvas, rows painted into a dirty rect, heights cached once",
        "a short one",
        "the viewport-sized backing is the whole trick — the layer never grows",
        "```swift\nlet answer = 42\n```",
        "> a quote, which parses one level in\n> and keeps its second line",
        "- a list\n- with two items",
    ]
}
