import Foundation

/// A message.
///
/// **The size of this type is a design constraint, not an afterthought.** A busy
/// session holds tens of thousands of them and the store copies them on every
/// edit, reaction and read-state pass. Everything a plain text message does not
/// have — attachments, embeds, reactions, mentions, a reply reference, an
/// interaction record — is behind `payload`, one optional class reference. A
/// plain "ok" from a friend is the common case and it costs 8 bytes for all of
/// it.
///
/// There is no `guildId` field, deliberately. Discord sends one on gateway
/// messages and omits it on everything fetched over REST — that is, on all
/// history — so a field that is present for the newest page and nil for every
/// page behind it invites exactly the bug it looks like it prevents: code reads
/// it, finds nil, and falls back to a linear scan over every guild and every
/// channel, per row, per evaluation. The channel knows its guild. Ask the
/// channel.
public struct Message: Hashable, Sendable, Identifiable, Codable {
    public var id: MessageID
    public var channelID: ChannelID
    public var authorID: UserID
    public var content: String
    /// Nil unless the message has been edited.
    public var editedAt: Date?
    public var kind: MessageKind
    public var flags: MessageFlags
    /// Whether the channel is holding this message on its pinned list.
    ///
    /// **A stored `Bool` rather than a per-channel set of pinned ids.** It
    /// costs nothing — it lands in the padding after `flags` — where a set
    /// would be a second table to keep in step with the transcript, and the
    /// pin state has to be right on a message the pins pane has never fetched.
    /// Discord sends it on every message object, on history and on the socket.
    public var isPinned: Bool
    /// Everything rare. Nil for a plain text message.
    public var payload: MessagePayload?

    /// When the message was sent. Derived from the snowflake rather than stored:
    /// the id already carries a millisecond timestamp, so a `Date` field would
    /// be 8 bytes per message duplicating a value that cannot disagree.
    public var sentAt: Date { id.timestamp }

    public init(
        id: MessageID,
        channelID: ChannelID,
        authorID: UserID,
        content: String = "",
        editedAt: Date? = nil,
        kind: MessageKind = .default,
        flags: MessageFlags = [],
        isPinned: Bool = false,
        payload: MessagePayload? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.authorID = authorID
        self.content = content
        self.editedAt = editedAt
        self.kind = kind
        self.flags = flags
        self.isPinned = isPinned
        self.payload = payload
    }

    /// The result of a poll that has ended, for a `POLL_RESULT` message.
    ///
    /// Nil for everything else, which is nearly every message — and nil for a
    /// `POLL_RESULT` whose embed Discord shaped differently, which draws the
    /// plain sentence rather than a claim the wire did not make.
    public var pollResult: PollResult? {
        guard kind == .pollResult,
              let embed = embeds.first(where: { $0.kind == "poll_result" }) ?? embeds.first
        else { return nil }
        func field(_ name: String) -> String? {
            embed.fields.first { $0.name == name }?.value
        }
        guard let question = field("poll_question_text") else { return nil }
        let emojiName = field("victor_answer_emoji_name")
        let emojiID = field("victor_answer_emoji_id").flatMap(UInt64.init).map(EmojiID.init(rawValue:))
        return PollResult(
            question: question,
            winner: field("victor_answer_text"),
            winnerEmoji: emojiName.map {
                EmojiRef(
                    id: emojiID,
                    name: $0,
                    isAnimated: field("victor_answer_emoji_animated") == "true"
                )
            },
            winnerVotes: field("victor_answer_votes").flatMap(Int.init) ?? 0,
            totalVotes: field("total_votes").flatMap(Int.init) ?? 0
        )
    }

    /// The embeds a transcript should draw.
    ///
    /// Everything but the kinds Discord never draws as a card (`581619`) and
    /// this client draws its own way: a poll result's, whose fields the row's
    /// own sentence already says — drawn as an ordinary card it is a grey box
    /// listing `victor_answer_id` at somebody — AutoMod's, and a safety
    /// notice's.
    public var drawableEmbeds: [Embed] {
        let drawn = embeds.filter {
            !Self.ownCardKinds.contains($0.kind ?? "")
                // A fake Nitro emoji's or sticker's unfurl: the thing itself
                // is drawn in the words, or under them.
                && $0.url.map { FakeNitroLink(url: $0) == nil } ?? true
        }
        return Embed.mergingGalleries(drawn)
    }

    private static func isOnlyFakeStickers(_ content: String) -> Bool {
        // Most messages carry no link at all, and this runs for every message
        // on every layout — a width change lays out the whole transcript.
        guard content.contains("http") else { return false }
        var rest = content
        for match in content.matches(of: linkPattern) {
            let url = match.output.1.map(String.init) ?? String(match.output.0)
            guard case .sticker? = FakeNitroLink(url: url) else { continue }
            rest = rest.replacingOccurrences(of: String(match.output.0), with: "")
        }
        return rest != content && rest.allSatisfy(\.isWhitespace)
    }

    /// A link, bare or masked. **Built once and kept**: a regex literal in a
    /// function body is parsed and compiled again on every call, and sampled
    /// during a sidebar toggle that was 40 % of the whole transcript's
    /// re-layout.
    nonisolated(unsafe) private static let linkPattern = /\[[^\]]*\]\((https?:\/\/[^)\s]+)\)|https?:\/\/\S+/

    /// The stickers to draw: the ones sent, and any sent as fake Nitro links —
    /// which the words no longer show. See `FakeNitroLink`.
    public var displayedStickers: [StickerRef] {
        let fake = FakeNitroLink.links(in: content).compactMap { link -> StickerRef? in
            if case .sticker(let sticker) = link { sticker } else { nil }
        }
        return stickers + fake
    }

    /// The embed kinds drawn as a card of their own rather than an embed.
    static let ownCardKinds: Set<String> = SafetyNotice.embedKinds.union([
        "poll_result", AutoModFields.messageKind, AutoModFields.notificationKind,
    ])

    /// The words to draw, which is not always the words that were sent.
    ///
    /// **A message that is nothing but a link to a picture draws the picture and
    /// not the link.** Discord does this and it is not cosmetic: the unfurl is
    /// already the whole message, so the address above it is the same thing said
    /// twice — once in a form nobody can read. Both of the shapes that reach
    /// this are one URL and one embed: a direct `cdn.discordapp.com/…/x.gif`
    /// link, and a Tenor page whose `gifv` unfurl *is* the GIF.
    ///
    /// **Every URL in the content has to be accounted for, and the whole content
    /// has to be URLs.** "look at this https://…gif" keeps its words, because
    /// the sentence is not the link; two links where only one unfurled keeps
    /// both, because dropping the text would lose the one that did not.
    ///
    /// Matched against the embed's own `url` — the address Discord says it
    /// unfurled — rather than against the media inside it, which is a different
    /// address on a different host after proxying.
    public var displayedContent: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return content }
        // Nothing but fake Nitro stickers: they are drawn as stickers, and the
        // words they were sent as leave nothing behind but an empty line.
        if Self.isOnlyFakeStickers(trimmed) { return "" }
        let sources = Set(
            drawableEmbeds.lazy
                .filter { $0.isBareImage }
                .compactMap(\.url)
        )
        guard !sources.isEmpty else { return content }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard words.allSatisfy({ sources.contains(String($0)) }) else { return content }
        return ""
    }

    public var attachments: [Attachment] { payload?.attachments ?? [] }
    public var embeds: [Embed] { payload?.embeds ?? [] }
    public var components: [ActionRow] { payload?.components ?? [] }
    /// The application to name when a button on this message is pressed.
    ///
    /// **`application_id` where Discord sent it, the author otherwise.** A bot
    /// user's id *is* its application id for every app registered since 2016,
    /// and the capture's two values agree — `slash help.har` presses a button on
    /// a message whose author is `949479338275913799` and posts an interaction
    /// naming `949479338275913799`. The field is preferred anyway because it is
    /// Discord's own answer rather than an identity this client is assuming.
    public var componentApplicationID: ApplicationID {
        payload?.applicationID ?? ApplicationID(rawValue: authorID.rawValue)
    }
    /// The live action button carrying this `custom_id`, if the message still
    /// has one.
    ///
    /// **Searched at press time, not carried from the draw.** A pager edits
    /// itself and the buttons on it change — the capture's Next goes dead on
    /// page 6 — so a click has to be checked against the message as it is now
    /// rather than against the slot that was laid out before the last edit.
    /// Both component paths are walked: an ordinary action row, and the
    /// Components V2 tree, where the pager in the capture actually lives.
    /// The live select menu with this `custom_id`, wherever the message has it.
    public func selectMenu(customID: String) -> MessageComponent? {
        for row in components {
            for control in row.components where control.select?.customID == customID {
                return control
            }
        }
        return DisplayComponent.firstControl(in: displayComponents) { $0.select?.customID == customID }
    }

    public func pressableComponent(customID: String) -> MessageComponent? {
        for row in components {
            for control in row.components where control.customID == customID {
                return control
            }
        }
        return DisplayComponent.firstControl(in: displayComponents) { $0.customID == customID }
    }

    /// Whether only the reader can see this message.
    ///
    /// An ephemeral message is delivered over the socket to the one session that
    /// caused it and exists nowhere else — it is not in history, and reopening
    /// the channel loses it. Saying so is the whole point of the note Discord
    /// draws under it.
    public var isEphemeral: Bool { flags.contains(.ephemeral) }
    public var displayComponents: [DisplayComponent] { payload?.displayComponents ?? [] }
    public var poll: Poll? { payload?.poll }
    public var stickers: [StickerRef] { payload?.stickers ?? [] }
    public var reactions: [Reaction] { payload?.reactions ?? [] }
    /// The thread started from this message. Nil for everything else.
    public var thread: MessageThread? { payload?.thread }
    /// What a reply quotes. Nil for everything else.
    public var reference: MessageReference? { payload?.reference }
    public var referencedMessageID: MessageID? { payload?.reference?.messageID }
    /// The message this one carries, when it is a forward.
    public var forwarded: ForwardedMessage? { payload?.forwarded }
    /// What a Server Hub message is about. Nil for everything else.
    public var guildSpaceData: GuildSpaceMessageData? { payload?.guildSpaceData }
    /// A call's record on its `CALL` message. Nil for everything else.
    public var call: MessageCall? { payload?.call }
    public var mentionedUserIDs: [UserID] { payload?.mentionedUserIDs ?? [] }
    /// The roles this message pinged. On the payload already — this is the
    /// accessor that was missing beside its two neighbours, which is why
    /// `bumpUnread` had only ever counted a *direct* mention.
    public var mentionedRoleIDs: [RoleID] { payload?.mentionedRoleIDs ?? [] }
    public var mentionsEveryone: Bool { payload?.mentionsEveryone ?? false }
    public var webhookID: UserID? { payload?.webhookID }
    /// The activity an app launched into this channel. Nil for everything else.
    public var activityInvite: ActivityInvite? { payload?.activityInvite }
    /// An invitation to listen along on the author's Spotify.
    public var listenAlong: ListenAlongInvite? { payload?.listenAlong }
    /// The activity this message replies to — Discord's component 16.
    public var contentEntry: RecentActivity? { payload?.contentEntry }
    /// Who invoked the command this message answers. Nil for everything a
    /// person typed.
    public var interaction: MessageInteraction? { payload?.interaction }
    /// The custom theme this message shares — Discord's theme card.
    public var sharedTheme: SharedClientTheme? { payload?.sharedTheme }
    /// The moment of a clip this reply is about — a timeline comment.
    public var mediaMention: MediaMention? { payload?.mediaMention }

    /// Whether the message shows nothing at all without its components.
    ///
    /// An app posting through Components V2 sends `content: ""` and no embeds,
    /// putting everything in `components`. A renderer that only knows about
    /// content and embeds draws an author line and a blank space, which is
    /// indistinguishable from a bug. The flag is the tell.
    public var isComponentsOnly: Bool {
        flags.contains(.isComponentsV2)
    }

    /// Whether the message has any renderable body at all.
    ///
    /// **An activity invitation counts, and it is the only body it has.** The
    /// captured launch message carries no content, no embed, no component and
    /// no attachment — the card is drawn entirely from `activityInvite` — so a
    /// check that omitted it would call the one thing on the row nothing.
    public var isEmpty: Bool {
        content.isEmpty && attachments.isEmpty && embeds.isEmpty
            && stickers.isEmpty && components.isEmpty && displayComponents.isEmpty
            && poll == nil && !isComponentsOnly && activityInvite == nil && listenAlong == nil
            && sharedTheme == nil
    }

    /// Whether this row addresses an *object* rather than something someone
    /// typed.
    ///
    /// Discord composes a call record server-side with no content, so Reply
    /// quotes an empty body, Forward delivers a call record to a channel it did
    /// not happen in, and Edit has nothing anyone wrote. Those actions are
    /// dropped from both the menu and the hover pill for these kinds.
    /// A message published from a followed announcement channel (`943667`):
    /// an ordinary message flagged as a crosspost, its reference the original.
    /// It is not a reply, and draws no quote above it.
    public var isCrosspost: Bool {
        kind == .default && flags.contains(.isCrosspost) && reference != nil
    }

    public var isSystemEvent: Bool {
        switch kind {
        case .default, .reply, .chatInputCommand, .contextMenuCommand, .threadStarterMessage:
            false
        // **Drawn as ordinary messages, as Discord draws them.** Its system
        // renderer map leaves these kinds out (`f1ea8c8b1054ad64`), so they go
        // down the normal path with their content, embeds and components.
        // Here they fell to the system row with no sentence, which says only
        // "Message".
        case .guildInviteReminder, .interactionPremiumUpsell, .guildDeadchatRevivePrompt,
             .customGift, .guildGamingStatsPrompt, .voiceHangoutInvite, .changelog,
             .hdStreamingUpgraded, .chatWallpaperSet, .chatWallpaperRemoved, .emojiAdded,
             .mediaMentionMessage:
            false
        default:
            true
        }
    }
}

/// Everything a message rarely has.
///
/// A final class so `Message` stays small and copying one copies a pointer. Its
/// stored properties are `let`, so a shared box can never be mutated out from
/// under another holder — an edit builds a new box.
public final class MessagePayload: Hashable, Sendable, Codable {
    public let attachments: [Attachment]
    public let embeds: [Embed]
    public let reactions: [Reaction]
    public let stickers: [StickerRef]
    /// The controls an app attached. Empty for everything a person typed, which
    /// is the overwhelming majority — the array costs a word on a box that only
    /// exists for messages that are already unusual.
    public let components: [ActionRow]
    /// The Components V2 tree, when the message is built out of one. Empty for
    /// everything else, which is nearly everything.
    public let displayComponents: [DisplayComponent]
    /// The poll, when there is one. A message carrying one has no body at all.
    public let poll: Poll?
    public let mentionedUserIDs: [UserID]
    public let mentionedRoleIDs: [RoleID]
    public let mentionsEveryone: Bool
    /// What a reply quotes: the target, and enough of it to draw the header
    /// above this message without a second fetch.
    public let reference: MessageReference?
    /// What a forward carries. Discord sends the whole quoted message as a
    /// *snapshot* rather than a pointer, deliberately — the original may be
    /// somewhere the reader cannot reach, and a forward has to render anyway.
    public let forwarded: ForwardedMessage?
    /// A webhook's author id belongs to no account. Kept distinct from
    /// `isBot` because webhooks set that too, and the difference decides whether
    /// asking the gateway for the author is a request that can ever be answered.
    public let webhookID: UserID?
    /// The nonce a pending send was posted with, so the echo can be matched to
    /// the optimistic row and replace it rather than duplicating it.
    public let nonce: String?
    /// The invitation card an activity launch leaves behind. Nil for every
    /// message a person wrote, which is why it is here rather than on `Message`.
    public let activityInvite: ActivityInvite?
    /// An invitation to listen along on somebody's Spotify — Discord's
    /// `message.activity` with a `spotify:` party. Nil for everything else.
    public let listenAlong: ListenAlongInvite?
    /// Who invoked the command this message answers, and what it was called.
    ///
    /// **Not activity-specific.** An activity launch and a slash command are
    /// the same thing on the wire — an interaction — and both draw the same
    /// "somebody used *name*" line above the reply. Keeping it general is what
    /// lets the second one arrive without a second header.
    public let interaction: MessageInteraction?
    /// The application that owns this message's controls.
    ///
    /// **Only on an interaction response or an application-owned webhook**,
    /// which is exactly where a pressable button lives. Pressing one names the
    /// application, and `Message.componentApplicationID` is what falls back to
    /// the author when Discord did not send this — a bot user's id *is* its
    /// application id for every app registered since 2016, and the capture's
    /// two values agree.
    public let applicationID: ApplicationID?
    /// The thread started from this message, when there is one. Nil for
    /// everything else, which is nearly every message.
    public let thread: MessageThread?
    /// The custom theme the message shares — `shared_client_theme`. Nil for
    /// everything else.
    public let sharedTheme: SharedClientTheme?
    /// A reply at a moment of a clip — `media_mention`, Discord's timeline
    /// comment. Nil for everything else.
    public let mediaMention: MediaMention?
    /// What a Server Hub message (type 69) is about — `guild_space_data`. Nil
    /// for everything else.
    public let guildSpaceData: GuildSpaceMessageData?
    /// The activity a reply is about — Discord's component 16
    /// (`content_inventory_entry`), the card a reply to somebody's activity
    /// carries into the conversation (docs/ACTIVITY-CARDS.md decision 11).
    public let contentEntry: RecentActivity?
    /// A call's record — `call`: who was in it and when it ended. Nil for
    /// everything else.
    public let call: MessageCall?

    public init(
        attachments: [Attachment] = [],
        embeds: [Embed] = [],
        reactions: [Reaction] = [],
        stickers: [StickerRef] = [],
        components: [ActionRow] = [],
        displayComponents: [DisplayComponent] = [],
        poll: Poll? = nil,
        mentionedUserIDs: [UserID] = [],
        mentionedRoleIDs: [RoleID] = [],
        mentionsEveryone: Bool = false,
        reference: MessageReference? = nil,
        forwarded: ForwardedMessage? = nil,
        webhookID: UserID? = nil,
        nonce: String? = nil,
        activityInvite: ActivityInvite? = nil,
        listenAlong: ListenAlongInvite? = nil,
        interaction: MessageInteraction? = nil,
        applicationID: ApplicationID? = nil,
        thread: MessageThread? = nil,
        sharedTheme: SharedClientTheme? = nil,
        mediaMention: MediaMention? = nil,
        guildSpaceData: GuildSpaceMessageData? = nil,
        contentEntry: RecentActivity? = nil,
        call: MessageCall? = nil
    ) {
        self.activityInvite = activityInvite
        self.listenAlong = listenAlong
        self.interaction = interaction
        self.applicationID = applicationID
        self.attachments = attachments
        self.embeds = embeds
        self.reactions = reactions
        self.stickers = stickers
        self.components = components
        self.displayComponents = displayComponents
        self.poll = poll
        self.mentionedUserIDs = mentionedUserIDs
        self.mentionedRoleIDs = mentionedRoleIDs
        self.mentionsEveryone = mentionsEveryone
        self.reference = reference
        self.forwarded = forwarded
        self.webhookID = webhookID
        self.nonce = nonce
        self.thread = thread
        self.sharedTheme = sharedTheme
        self.mediaMention = mediaMention
        self.guildSpaceData = guildSpaceData
        self.contentEntry = contentEntry
        self.call = call
    }

    /// The same box with one array replaced.
    ///
    /// **A copy helper rather than the constructor written out at each call
    /// site.** The properties here are `let` so a shared box can never be
    /// mutated out from under another holder, which means every change is a
    /// full re-construction — and a re-construction written by hand is a
    /// re-construction that silently drops whatever field was added last. Both
    /// call sites in the app had done exactly that: a reaction arriving on a
    /// message with a poll rebuilt the box without the poll, and the tally
    /// vanished on the next thumbs-up.
    public func replacingReactions(_ reactions: [Reaction]) -> MessagePayload {
        MessagePayload(
            attachments: attachments,
            embeds: embeds,
            reactions: reactions,
            stickers: stickers,
            components: components,
            displayComponents: displayComponents,
            poll: poll,
            mentionedUserIDs: mentionedUserIDs,
            mentionedRoleIDs: mentionedRoleIDs,
            mentionsEveryone: mentionsEveryone,
            reference: reference,
            forwarded: forwarded,
            webhookID: webhookID,
            nonce: nonce,
            activityInvite: activityInvite,
            listenAlong: listenAlong,
            interaction: interaction,
            applicationID: applicationID,
            thread: thread,
            sharedTheme: sharedTheme,
            mediaMention: mediaMention,
            guildSpaceData: guildSpaceData,
            contentEntry: contentEntry,
            call: call
        )
    }

    /// The same box with different attachments. See `replacingReactions`.
    public func replacingAttachments(_ attachments: [Attachment]) -> MessagePayload {
        MessagePayload(
            attachments: attachments,
            embeds: embeds,
            reactions: reactions,
            stickers: stickers,
            components: components,
            displayComponents: displayComponents,
            poll: poll,
            mentionedUserIDs: mentionedUserIDs,
            mentionedRoleIDs: mentionedRoleIDs,
            mentionsEveryone: mentionsEveryone,
            reference: reference,
            forwarded: forwarded,
            webhookID: webhookID,
            nonce: nonce,
            activityInvite: activityInvite,
            listenAlong: listenAlong,
            interaction: interaction,
            applicationID: applicationID,
            thread: thread,
            sharedTheme: sharedTheme,
            mediaMention: mediaMention,
            guildSpaceData: guildSpaceData,
            contentEntry: contentEntry,
            call: call
        )
    }

    /// The same box with a different poll. See `replacingReactions`.
    public func replacingPoll(_ poll: Poll?) -> MessagePayload {
        MessagePayload(
            attachments: attachments,
            embeds: embeds,
            reactions: reactions,
            stickers: stickers,
            components: components,
            displayComponents: displayComponents,
            poll: poll,
            mentionedUserIDs: mentionedUserIDs,
            mentionedRoleIDs: mentionedRoleIDs,
            mentionsEveryone: mentionsEveryone,
            reference: reference,
            forwarded: forwarded,
            webhookID: webhookID,
            nonce: nonce,
            activityInvite: activityInvite,
            listenAlong: listenAlong,
            interaction: interaction,
            applicationID: applicationID,
            thread: thread,
            sharedTheme: sharedTheme,
            mediaMention: mediaMention,
            guildSpaceData: guildSpaceData,
            contentEntry: contentEntry,
            call: call
        )
    }

    /// The same box with a different reply header. See `replacingReactions`.
    /// The same payload with the thread record swapped — how a thread card
    /// learns its newest message and count after the page has loaded.
    public func replacingThread(_ thread: MessageThread?) -> MessagePayload {
        MessagePayload(
            attachments: attachments,
            embeds: embeds,
            reactions: reactions,
            stickers: stickers,
            components: components,
            displayComponents: displayComponents,
            poll: poll,
            mentionedUserIDs: mentionedUserIDs,
            mentionedRoleIDs: mentionedRoleIDs,
            mentionsEveryone: mentionsEveryone,
            reference: reference,
            forwarded: forwarded,
            webhookID: webhookID,
            nonce: nonce,
            activityInvite: activityInvite,
            listenAlong: listenAlong,
            interaction: interaction,
            applicationID: applicationID,
            thread: thread,
            sharedTheme: sharedTheme,
            mediaMention: mediaMention,
            guildSpaceData: guildSpaceData,
            contentEntry: contentEntry,
            call: call
        )
    }

    public func replacingReference(_ reference: MessageReference?) -> MessagePayload {
        MessagePayload(
            attachments: attachments,
            embeds: embeds,
            reactions: reactions,
            stickers: stickers,
            components: components,
            displayComponents: displayComponents,
            poll: poll,
            mentionedUserIDs: mentionedUserIDs,
            mentionedRoleIDs: mentionedRoleIDs,
            mentionsEveryone: mentionsEveryone,
            reference: reference,
            forwarded: forwarded,
            webhookID: webhookID,
            nonce: nonce,
            activityInvite: activityInvite,
            listenAlong: listenAlong,
            interaction: interaction,
            applicationID: applicationID,
            thread: thread,
            sharedTheme: sharedTheme,
            mediaMention: mediaMention,
            guildSpaceData: guildSpaceData,
            contentEntry: contentEntry,
            call: call
        )
    }

    /// Whether the box is worth allocating. A decoder that builds one of these
    /// for every plain message has undone the point of the type.
    public var isEmpty: Bool {
        attachments.isEmpty && embeds.isEmpty && reactions.isEmpty
            && stickers.isEmpty && components.isEmpty && displayComponents.isEmpty
            && poll == nil && mentionedUserIDs.isEmpty
            && mentionedRoleIDs.isEmpty && !mentionsEveryone
            && reference == nil && forwarded == nil && webhookID == nil && nonce == nil
            && activityInvite == nil && listenAlong == nil && interaction == nil && thread == nil
            && sharedTheme == nil && mediaMention == nil && guildSpaceData == nil && contentEntry == nil
            && call == nil
    }

    public static func == (lhs: MessagePayload, rhs: MessagePayload) -> Bool {
        // Identity first. Two messages that share a box — every copy of one
        // message in the store — settle in a pointer compare, which is the
        // common case by a wide margin.
        lhs === rhs
            || (lhs.attachments == rhs.attachments
                && lhs.embeds == rhs.embeds
                && lhs.reactions == rhs.reactions
                && lhs.stickers == rhs.stickers
                && lhs.components == rhs.components
                && lhs.displayComponents == rhs.displayComponents
                && lhs.poll == rhs.poll
                && lhs.mentionedUserIDs == rhs.mentionedUserIDs
                && lhs.mentionedRoleIDs == rhs.mentionedRoleIDs
                && lhs.mentionsEveryone == rhs.mentionsEveryone
                && lhs.reference == rhs.reference
                && lhs.forwarded == rhs.forwarded
                && lhs.webhookID == rhs.webhookID
                && lhs.activityInvite == rhs.activityInvite
                && lhs.listenAlong == rhs.listenAlong
                && lhs.interaction == rhs.interaction
                && lhs.thread == rhs.thread
                && lhs.sharedTheme == rhs.sharedTheme
                && lhs.mediaMention == rhs.mediaMention
                && lhs.guildSpaceData == rhs.guildSpaceData
                && lhs.contentEntry == rhs.contentEntry
                && lhs.call == rhs.call)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(attachments.count)
        hasher.combine(embeds.count)
        hasher.combine(reactions.count)
        hasher.combine(reference?.messageID)
    }
}

public enum MessageKind: Int, Hashable, Sendable, Codable {
    case `default` = 0
    case recipientAdd = 1
    case recipientRemove = 2
    case call = 3
    case channelNameChange = 4
    case channelIconChange = 5
    case channelPinnedMessage = 6
    case userJoin = 7
    case guildBoost = 8
    case guildBoostTier1 = 9
    case guildBoostTier2 = 10
    case guildBoostTier3 = 11
    case channelFollowAdd = 12
    case threadCreated = 18
    case reply = 19
    case chatInputCommand = 20
    case threadStarterMessage = 21
    case contextMenuCommand = 23
    case autoModerationAction = 24
    /// A stage went live; `content` is its topic.
    case stageStart = 27
    /// A stage ended; `content` is the topic it had.
    case stageEnd = 28
    /// Somebody stepped up to speak on a stage.
    case stageSpeaker = 29
    /// Somebody raised their hand on a stage.
    case stageRaiseHand = 30
    /// A live stage's topic changed; `content` is the new one.
    case stageTopic = 31
    /// A poll that has ended. **Its words are in an embed, not in `content`** —
    /// see `Message.pollResult` — so a renderer that only knows about content
    /// draws an author line over a blank row, which is what a closed poll looked
    /// like in this app.
    case pollResult = 46
    /// A Server Hub event: the whiteboard is busy, the leaderboard turned over,
    /// the music has a new top (`guild_space_data`).
    case guildSpace = 69
    // The rest of Discord's kinds (`MessageTypes` in the web bundle), so none
    // of them is mistaken for an unknown one. Those Discord draws as a line
    // have one in `SystemMessageText`; the ones it draws as ordinary messages
    // are listed in `isSystemEvent`.
    case guildStream = 13
    case guildDiscoveryDisqualified = 14
    case guildDiscoveryRequalified = 15
    case guildDiscoveryGracePeriodInitialWarning = 16
    case guildDiscoveryGracePeriodFinalWarning = 17
    case guildInviteReminder = 22
    case roleSubscriptionPurchase = 25
    case interactionPremiumUpsell = 26
    case guildApplicationPremiumSubscription = 32
    case privateChannelIntegrationAdded = 33
    case privateChannelIntegrationRemoved = 34
    case premiumReferral = 35
    case guildIncidentAlertModeEnabled = 36
    case guildIncidentAlertModeDisabled = 37
    case guildIncidentReportRaid = 38
    case guildIncidentReportFalseAlarm = 39
    case guildDeadchatRevivePrompt = 40
    case customGift = 41
    case guildGamingStatsPrompt = 42
    case purchaseNotification = 44
    case voiceHangoutInvite = 45
    case changelog = 47
    case nitroNotification = 48
    case channelLinkedToLobby = 49
    case giftingPrompt = 50
    case inGameMessageNux = 51
    case guildJoinRequestAccepted = 52
    case guildJoinRequestRejected = 53
    case guildJoinRequestWithdrawn = 54
    case hdStreamingUpgraded = 55
    case chatWallpaperSet = 56
    case chatWallpaperRemoved = 57
    case reportToModDeletedMessage = 58
    case reportToModTimeoutUser = 59
    case reportToModKickUser = 60
    case reportToModBanUser = 61
    case reportToModClosedReport = 62
    case emojiAdded = 63
    case premiumGroupInvite = 64
    /// Somebody started a voice hangout.
    case voiceSession = 65
    /// A friend request was accepted; `content` is the note it came with.
    case friendRequestAccepted = 67
    /// A comment at a moment of a clip — an ordinary message.
    case mediaMentionMessage = 68
    case unknown = -1

    public init(rawValue: Int) {
        self = switch rawValue {
        case 0: .default
        case 1: .recipientAdd
        case 2: .recipientRemove
        case 3: .call
        case 4: .channelNameChange
        case 5: .channelIconChange
        case 6: .channelPinnedMessage
        case 7: .userJoin
        case 8: .guildBoost
        case 9: .guildBoostTier1
        case 10: .guildBoostTier2
        case 11: .guildBoostTier3
        case 12: .channelFollowAdd
        case 18: .threadCreated
        case 19: .reply
        case 20: .chatInputCommand
        case 21: .threadStarterMessage
        case 23: .contextMenuCommand
        case 24: .autoModerationAction
        case 27: .stageStart
        case 28: .stageEnd
        case 29: .stageSpeaker
        case 30: .stageRaiseHand
        case 31: .stageTopic
        case 46: .pollResult
        case 69: .guildSpace
        case 13: .guildStream
        case 14: .guildDiscoveryDisqualified
        case 15: .guildDiscoveryRequalified
        case 16: .guildDiscoveryGracePeriodInitialWarning
        case 17: .guildDiscoveryGracePeriodFinalWarning
        case 22: .guildInviteReminder
        case 25: .roleSubscriptionPurchase
        case 26: .interactionPremiumUpsell
        case 32: .guildApplicationPremiumSubscription
        case 33: .privateChannelIntegrationAdded
        case 34: .privateChannelIntegrationRemoved
        case 35: .premiumReferral
        case 36: .guildIncidentAlertModeEnabled
        case 37: .guildIncidentAlertModeDisabled
        case 38: .guildIncidentReportRaid
        case 39: .guildIncidentReportFalseAlarm
        case 40: .guildDeadchatRevivePrompt
        case 41: .customGift
        case 42: .guildGamingStatsPrompt
        case 44: .purchaseNotification
        case 45: .voiceHangoutInvite
        case 47: .changelog
        case 48: .nitroNotification
        case 49: .channelLinkedToLobby
        case 50: .giftingPrompt
        case 51: .inGameMessageNux
        case 52: .guildJoinRequestAccepted
        case 53: .guildJoinRequestRejected
        case 54: .guildJoinRequestWithdrawn
        case 55: .hdStreamingUpgraded
        case 56: .chatWallpaperSet
        case 57: .chatWallpaperRemoved
        case 58: .reportToModDeletedMessage
        case 59: .reportToModTimeoutUser
        case 60: .reportToModKickUser
        case 61: .reportToModBanUser
        case 62: .reportToModClosedReport
        case 63: .emojiAdded
        case 64: .premiumGroupInvite
        case 65: .voiceSession
        case 67: .friendRequestAccepted
        case 68: .mediaMentionMessage
        default: .unknown
        }
    }
}

public struct MessageFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let crossposted = MessageFlags(rawValue: 1 << 0)
    public static let isCrosspost = MessageFlags(rawValue: 1 << 1)
    public static let suppressEmbeds = MessageFlags(rawValue: 1 << 2)
    public static let sourceMessageDeleted = MessageFlags(rawValue: 1 << 3)
    public static let urgent = MessageFlags(rawValue: 1 << 4)
    public static let hasThread = MessageFlags(rawValue: 1 << 5)
    public static let ephemeral = MessageFlags(rawValue: 1 << 6)
    public static let loading = MessageFlags(rawValue: 1 << 7)
    public static let suppressNotifications = MessageFlags(rawValue: 1 << 12)
    public static let isVoiceMessage = MessageFlags(rawValue: 1 << 13)
    /// The message renders entirely from `components`. See
    /// `Message.isComponentsOnly`.
    public static let isComponentsV2 = MessageFlags(rawValue: 1 << 15)
    /// Its author's account is suspended, and Discord asks clients to hide the
    /// message — folded under "messages removed from a suspended account",
    /// which cannot be opened. See `CollapsedGroup`.
    public static let hiddenSuspendedUser = MessageFlags(rawValue: 1 << 17)
}

public struct Attachment: Hashable, Sendable, Identifiable, Codable {
    public var id: AttachmentID
    public var filename: String
    public var url: String
    public var proxyURL: String
    public var contentType: String?
    public var size: Int
    public var width: Int?
    public var height: Int?
    /// The picture's own pixels, when Discord sent them — the shape a resized
    /// copy is asked for in (`CDN.resizedAttachment`).
    public var pixelSize: CGSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
    /// A spoilered attachment is named `SPOILER_…` by the uploader; Discord
    /// carries no flag for it.
    public var isSpoiler: Bool { filename.hasPrefix("SPOILER_") }
    public var description: String?
    /// Voice message waveform, base64. Present only on voice notes.
    public var waveform: String?
    public var durationSeconds: Double?
    /// Discord's `IS_ANIMATED` mark — the server's own reading that the file
    /// moves. It decides a WebP, whose extension says nothing; see
    /// `CDN.playsAsAnimated`.
    public var isMarkedAnimated: Bool
    /// Discord's blurred stand-in, drawn until the picture lands — see
    /// `MediaPlaceholder`.
    public var placeholder: String?
    /// A Discord clip: who was in it, what happened in it — nil for any other
    /// file. docs/CLIPS-PRESENCE.md, Phase 4.1.
    public var clip: AttachmentClip?
    /// Discord's `IS_THUMBNAIL`: the picture a media post chose to stand for it on
    /// its board.
    public var isThumbnail = false

    public init(
        id: AttachmentID,
        filename: String,
        url: String,
        proxyURL: String,
        contentType: String? = nil,
        size: Int = 0,
        width: Int? = nil,
        height: Int? = nil,
        description: String? = nil,
        waveform: String? = nil,
        durationSeconds: Double? = nil,
        isMarkedAnimated: Bool = false,
        placeholder: String? = nil,
        clip: AttachmentClip? = nil,
        isThumbnail: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.url = url
        self.proxyURL = proxyURL
        self.contentType = contentType
        self.size = size
        self.width = width
        self.height = height
        self.description = description
        self.waveform = waveform
        self.durationSeconds = durationSeconds
        self.isMarkedAnimated = isMarkedAnimated
        self.placeholder = placeholder
        self.clip = clip
        self.isThumbnail = isThumbnail
    }

    /// A picture, by its type **or by its name**, as Discord's client reads
    /// it: attachments from before Discord sent `content_type` (early 2021
    /// and older) carry none, and Discord still draws them — a server's
    /// 2021 welcome screenshot was a file card here (Alex's image 245,
    /// 2026-11-19). Discord's list, from its bundle:
    /// `/\.(png|jpe?g|jfif|webp|gif|heic|heif|dng|avif)$/i`.
    public var isImage: Bool {
        if contentType?.hasPrefix("image/") == true { return true }
        return Self.extensionOf(filename).map(Self.imageExtensions.contains) ?? false
    }

    /// A video, by its type or its name — `/\.(mp4|webm|mov|qt)$/i`.
    public var isVideo: Bool {
        if contentType?.hasPrefix("video/") == true { return true }
        guard contentType?.hasPrefix("image/") != true else { return false }
        return Self.extensionOf(filename).map(Self.videoExtensions.contains) ?? false
    }

    /// A sound, by its type or its name —
    /// `/\.(mp3|m4a|wav|aif|aiff|ogg|opus|flac)$/i`.
    public var isAudio: Bool {
        if contentType?.hasPrefix("audio/") == true { return true }
        guard contentType == nil else { return false }
        return Self.extensionOf(filename).map(Self.audioExtensions.contains) ?? false
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "jfif", "webp", "gif", "heic", "heif", "dng", "avif"]
    static let videoExtensions: Set<String> = ["mp4", "webm", "mov", "qt"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "ogg", "opus", "flac"]

    /// The name's extension, lowercased — nil for a name without one.
    public static func extensionOf(_ filename: String) -> String? {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return nil }
        let ext = filename[filename.index(after: dot)...]
        return ext.isEmpty ? nil : ext.lowercased()
    }

    /// Whether Discord's client plays it as moving. See `CDN.playsAsAnimated`.
    public var playsAsAnimated: Bool {
        CDN.playsAsAnimated(url, isMarkedAnimated: isMarkedAnimated)
    }

    /// The intrinsic aspect ratio, or nil when Discord sent no dimensions.
    ///
    /// Nil is a real state: a layout that substitutes 1.0 reserves a square for
    /// a panorama and then jumps when the picture arrives.
    public var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }
}

/// One emoji's reactions on a message: the plain ones and the super ones.
///
/// **Two tallies in one value, because Discord keeps them in one.** A message
/// carries one entry per emoji, and that entry holds a count of each kind — so
/// an emoji somebody super reacted with and somebody else reacted to plainly is
/// ONE entry drawn as TWO chips. `ReactionKind` names which half a chip is.
///
/// **`count` is the plain tally, not the wire's `count`.** The wire's is the
/// total of both kinds — `194` for an emoji with 194 super reactions and no
/// plain ones, captured — and Discord's client throws it away in favour of
/// `count_details.normal` the moment a message is decoded. Drawing the wire's
/// number is how a super reaction used to show up here as a second copy of
/// itself inside the plain chip.
public struct Reaction: Hashable, Sendable, Codable {
    public var emoji: EmojiRef
    /// Plain reactions: `count_details.normal`.
    public var count: Int
    /// The reader has reacted plainly: `me`.
    public var isMine: Bool
    /// Super reactions: `count_details.burst`.
    public var burstCount: Int
    /// The reader has super reacted: `me_burst`.
    public var isMineBurst: Bool
    /// The colours a super reaction chip is derived from, packed `0xRRGGBB`.
    ///
    /// **The first three of `burst_colors` and no more**, because that is all
    /// Discord ever reads: `SuperReactionPalette` picks the most vivid of the
    /// first three and derives everything else from that one. The server sends
    /// up to ten. Empty on an emoji nobody super reacted with.
    public var burstColors: [UInt32]

    public init(
        emoji: EmojiRef,
        count: Int,
        isMine: Bool,
        burstCount: Int = 0,
        isMineBurst: Bool = false,
        burstColors: [UInt32] = []
    ) {
        self.emoji = emoji
        self.count = count
        self.isMine = isMine
        self.burstCount = burstCount
        self.isMineBurst = isMineBurst
        self.burstColors = burstColors
    }

    /// One half's tally.
    public func count(of kind: ReactionKind) -> Int {
        kind == .burst ? burstCount : count
    }

    /// Whether the reader is in one half.
    public func isMine(_ kind: ReactionKind) -> Bool {
        kind == .burst ? isMineBurst : isMine
    }
}

/// The thread hanging off a message, as its chip needs it.
///
/// **Captured**, `threads.har`: `GET /channels/{id}/messages` returns a whole
/// nested channel object under `thread` on any message that started one — name,
/// `message_count`, `thread_metadata` and all. So the chip needs no second
/// fetch and no active-threads sweep; the transcript already has everything it
/// draws.
///
/// A summary rather than the `Channel` itself: the chip needs three fields, and
/// the full channel goes into `ChannelIndex` on the same page so that opening it
/// resolves. Holding a second copy here is how the chip and the panel come to
/// disagree about the thread's name.
public struct MessageThread: Hashable, Sendable, Codable {
    public var id: ChannelID
    public var name: String
    /// What the chip says. `total_message_sent` where Discord sends it, because
    /// it never decrements — see `Channel.threadMessageCount`.
    public var messageCount: Int
    public var isArchived: Bool
    /// The thread's `last_message_id`: when it last moved, for a card with no
    /// newer message to show.
    public var lastMessageID: MessageID?
    /// `thread_metadata.create_timestamp`: when it was made, for a thread with
    /// no message id to read a time from.
    public var createdAt: Date?
    /// The newest message, where Discord has said what it is: a thread sync's
    /// `most_recent_messages`, a live message, or the thread's own newest page
    /// (Discord's `ThreadMessageStore`, `456874`).
    public var latest: ThreadLatestMessage?

    public init(
        id: ChannelID,
        name: String,
        messageCount: Int,
        isArchived: Bool = false,
        lastMessageID: MessageID? = nil,
        createdAt: Date? = nil,
        latest: ThreadLatestMessage? = nil
    ) {
        self.id = id
        self.name = name
        self.messageCount = messageCount
        self.isArchived = isArchived
        self.lastMessageID = lastMessageID
        self.createdAt = createdAt
        self.latest = latest
    }

    /// When the thread last moved, in Discord's order (`707539.JO`): its newest
    /// message, then when it was made, then its own id.
    public var lastActivity: Date {
        let newest = [latest?.id, lastMessageID].compactMap { $0 }.max { $0.rawValue < $1.rawValue }
        return newest?.timestamp ?? createdAt ?? id.timestamp
    }

    /// The card's link, in Discord's words and rules (`321045`): "See Thread ›"
    /// with nothing counted, "50+" for a thread from before Discord counted
    /// past fifty, "100k+" past a hundred thousand.
    public var countLabel: String {
        let count = max(0, messageCount)
        guard count > 0 else { return "See Thread \u{203A}" }
        let shown: String
        if count >= 50, id.rawValue <= Self.lastCappedThreadID {
            shown = "50+"
        } else if count >= 100_000 {
            shown = "100k+"
        } else {
            shown = String(count)
        }
        return count == 1 ? "1 Message \u{203A}" : "\(shown) Messages \u{203A}"
    }

    /// Threads up to this id were counted only to fifty (Discord's
    /// `992549565104128000`).
    public static let lastCappedThreadID: UInt64 = 992_549_565_104_128_000
}

/// A thread's newest message, as its card draws it: who, one line of what, and
/// when (Discord's `ThreadMessageAccessoryMessage`).
public struct ThreadLatestMessage: Hashable, Sendable, Codable {
    public var id: MessageID
    public var authorID: UserID
    /// One line, markdown folded away — the reply header's own excerpt.
    public var excerpt: String
    /// Nothing to quote but a file or a sticker: the card says so in words.
    public var hasAttachment: Bool

    public init(id: MessageID, authorID: UserID, excerpt: String, hasAttachment: Bool) {
        self.id = id
        self.authorID = authorID
        self.excerpt = excerpt
        self.hasAttachment = hasAttachment
    }

    /// From the message itself, by the rules the reply header uses.
    public init(_ message: Message) {
        self.init(
            id: message.id,
            authorID: message.authorID,
            excerpt: message.flags.contains(.isVoiceMessage)
                ? MessageReference.voiceMessageExcerpt
                : MessageReference.excerpt(of: message.content),
            hasAttachment: !message.attachments.isEmpty || !message.stickers.isEmpty
        )
    }

    /// Whether a message can be a thread's newest: never the starter Discord
    /// copies into the thread, nor a forum post's own opening message (both
    /// left out by `ThreadMessageStore`).
    public static func counts(_ message: Message, inThread threadID: ChannelID) -> Bool {
        message.kind != .threadStarterMessage && message.id.rawValue != threadID.rawValue
    }
}

/// An emoji, either a Unicode sequence or a custom upload.
public struct EmojiRef: Hashable, Sendable, Codable {
    /// Nil for a Unicode emoji.
    public var id: EmojiID?
    /// The Unicode sequence, or the custom emoji's name.
    public var name: String
    public var isAnimated: Bool

    public init(id: EmojiID? = nil, name: String, isAnimated: Bool = false) {
        self.id = id
        self.name = name
        self.isAnimated = isAnimated
    }

    public var isCustom: Bool { id != nil }

    /// Whether two refs name the same reaction — Discord's own test, `i6` in
    /// module `815807`: by id for a custom emoji, by the sequence for a Unicode
    /// one.
    ///
    /// **Not `==`**, which also compares `name` and `isAnimated`. A custom
    /// emoji renamed since the page loaded, or an event that leaves `animated`
    /// out, is still the same reaction — and `==` would put a second chip for
    /// it beside the first.
    public func isSameReaction(as other: EmojiRef) -> Bool {
        if let id = other.id { return id == self.id }
        return self.id == nil && name == other.name
    }

    /// The same identity as a hashable value, for keying anything per
    /// reaction — a playing effect, a tooltip's answer.
    public var reactionKey: ReactionEmojiKey {
        if let id { return .custom(id) }
        return .unicode(name)
    }

    /// The form Discord's reaction routes want in a path segment: `name:id` for
    /// a custom emoji, the bare sequence for a Unicode one.
    public var apiIdentifier: String {
        if let id { return "\(name):\(id.rawValue)" }
        return name
    }

    /// What a picker types into the composer.
    ///
    /// A custom emoji goes out as Discord's inline form — `<:name:id>`, with the
    /// `a` prefix when it is animated — which every other client unfurls back
    /// into the picture. A Unicode one is just itself.
    public var messageToken: String {
        guard let id else { return name }
        return "<\(isAnimated ? "a" : ""):\(name):\(id.rawValue)>"
    }
}

public struct StickerRef: Hashable, Sendable, Identifiable, Codable {
    public enum Format: Int, Hashable, Sendable, Codable {
        case png = 1
        case apng = 2
        case lottie = 3
        case gif = 4
        case unknown = -1

        public init(rawValue: Int) {
            self = switch rawValue {
            case 1: .png
            case 2: .apng
            case 3: .lottie
            case 4: .gif
            default: .unknown
            }
        }

        /// Whether the picture moves.
        ///
        /// All three moving formats end up as the same filmstrip: APNG and GIF
        /// through `CGImageSource`, Lottie through the rasteriser. **Lottie has
        /// no bitmap on the CDN at all** — measured, both its `.png` and `.gif`
        /// endpoints answer 404 — so it has no still to fall back on and its
        /// cell is empty until the strip lands.
        public var isAnimated: Bool { self != .png }
    }

    public var id: UInt64
    public var name: String
    public var format: Format

    public init(id: UInt64, name: String, format: Format) {
        self.id = id
        self.name = name
        self.format = format
    }
}

/// What a reply quotes.
///
/// **A snapshot, not a pointer.** The target may be a thousand messages above
/// what is loaded, in a channel that has been evicted, or deleted outright — and
/// the header above the reply still has to draw. Discord sends the whole
/// referenced message inline for exactly this reason, and everything the header
/// needs is flattened here at decode: the author's id, one line of text, and
/// whether there was a picture instead of words.
///
/// Flattening at decode rather than at layout is deliberate. The header is drawn
/// by a canvas that runs off the main actor and cannot reach the store, and
/// folding a markdown tree into a line per row per frame is the cost
/// `MarkdownDocument.plainText` exists to pay once.
public struct MessageReference: Hashable, Sendable, Codable {
    public var messageID: MessageID?
    public var channelID: ChannelID?
    /// The server the referenced message is in. A crosspost's is the server
    /// that published it — which is what its SERVER card shows, and what makes
    /// one of Discord's own OFFICIAL.
    public var guildID: GuildID?
    /// Nil when the reference arrived with no message behind it — deleted, or
    /// out of reach. The header then says so rather than drawing a blank quote.
    public var authorID: UserID?
    public var isAuthorBot: Bool
    /// The quoted line, already flattened.
    public var excerpt: String
    /// Whether the quoted message was a picture or a file rather than words.
    public var hasAttachment: Bool
    /// Whether Discord said the quoted message is **gone** — `referenced_message`
    /// sent as `null` — rather than simply not sent.
    ///
    /// **Two states with one symptom, and Discord tells them apart.** A key
    /// that is absent means the server did not look the message up, so its
    /// fate is unknown: "Message could not be loaded", and the line still jumps
    /// to it. Only an explicit `null` is "Original message was deleted"
    /// (Discord's `ReferencedMessageState` `NOT_LOADED` and `DELETED`).
    public var isDeleted: Bool

    public init(
        messageID: MessageID? = nil,
        channelID: ChannelID? = nil,
        guildID: GuildID? = nil,
        authorID: UserID? = nil,
        isAuthorBot: Bool = false,
        excerpt: String = "",
        hasAttachment: Bool = false,
        isDeleted: Bool = false
    ) {
        self.messageID = messageID
        self.channelID = channelID
        self.guildID = guildID
        self.authorID = authorID
        self.isAuthorBot = isAuthorBot
        self.excerpt = excerpt
        self.hasAttachment = hasAttachment
        self.isDeleted = isDeleted
    }

    /// Whether Discord sent a reference with nothing behind it — deleted, or
    /// never looked up. `isDeleted` says which.
    public var isUnavailable: Bool { authorID == nil }

    /// One line of a quoted body: markdown folded, newlines collapsed, and cut
    /// well past anything a header can show.
    ///
    /// **Folded once, at decode.** The header is drawn by a canvas that runs off
    /// the main actor and cannot reach a parser cache; doing this per row per
    /// frame is the cost `MarkdownDocument.plainText` exists to pay once.
    ///
    /// The cut is a *character* bound rather than a measured width, because this
    /// runs with no font in hand. The painter truncates to the real width; this
    /// only stops a ten-kilobyte code block being carried around in every copy
    /// of the message that quotes it.
    /// What a reply says of the voice message it answers.
    public static let voiceMessageExcerpt = "Voice message"

    public static func excerpt(of content: String) -> String {
        guard !content.isEmpty else { return "" }
        let plain = MarkdownParser().parse(content).plainText
        var line = ""
        line.reserveCapacity(min(plain.count, excerptLimit))
        var wasSpace = false
        for character in plain {
            if character.isNewline || character == "\t" || character == " " {
                wasSpace = true
                continue
            }
            if wasSpace, !line.isEmpty { line.append(" ") }
            wasSpace = false
            line.append(character)
            if line.count >= excerptLimit { break }
        }
        return line
    }

    private static let excerptLimit = 180
}

/// The message a forward carries.
///
/// **A copy, and Discord means it as one.** A forward's snapshot has no author:
/// the whole point of the shape is that the original's identity does not travel
/// with it. A client that invents one — from the reference's channel, from the
/// forwarder — is asserting something the payload deliberately does not say.
/// What a closed poll says about itself.
///
/// **Read out of an embed, because that is where Discord puts it.** A
/// `POLL_RESULT` message has empty content and one embed of kind `poll_result`
/// whose *fields* carry the question, the winning answer and the counts. They
/// are fields rather than a payload, so the names below are the wire's and a
/// typo in one is a nil rather than a failure.
public struct PollResult: Hashable, Sendable {
    public var question: String
    /// The answer that won, when anybody voted.
    public var winner: String?
    public var winnerEmoji: EmojiRef?
    public var winnerVotes: Int
    public var totalVotes: Int

    /// The winner's share, 0...1. Zero when nobody voted, which is a real state:
    /// a poll can close with no votes at all.
    public var share: Double {
        guard totalVotes > 0 else { return 0 }
        return Double(winnerVotes) / Double(totalVotes)
    }
}

public struct ForwardedMessage: Hashable, Sendable, Codable {
    public var content: String
    /// **The snapshot's own attachments, not a count of them.** Discord sends
    /// the whole forwarded message under `message_snapshots` — content,
    /// attachments and embeds — and a client that kept only a number has
    /// nothing to draw: a forwarded photograph renders as an author line over
    /// empty space, which is what a forward looked like in this app.
    public var attachments: [Attachment]
    public var embeds: [Embed]
    /// The snapshot's stickers — `sticker_items`, as on any message.
    public var stickers: [StickerRef]
    /// Where it was forwarded from, when the reference named it. Only ever used
    /// to say "from #channel"; never to attribute the message to anybody.
    public var channelID: ChannelID?
    /// The original's server and id, from the reference: what Discord's
    /// footer jumps to (its forward breadcrumb), previewing the server first
    /// when the reader is not in it.
    public var guildID: GuildID?
    public var messageID: MessageID?
    /// When the original was sent — the snapshot's own `timestamp`, else the
    /// referenced id's moment, as Discord's footer reads it.
    public var timestamp: Date?

    public var attachmentCount: Int { attachments.count }
    public var hasEmbed: Bool { !embeds.isEmpty }

    /// Whether there is anything at all inside the quote. A forward with an
    /// empty snapshot is a real state — a message that has since been deleted —
    /// and the block still draws its label rather than a bare rule.
    public var isEmpty: Bool {
        content.isEmpty && attachments.isEmpty && embeds.isEmpty && stickers.isEmpty
    }

    /// The moment the footer shows: the snapshot's, else the one the original's
    /// id encodes.
    public var sentAt: Date? { timestamp ?? messageID?.timestamp }

    public init(
        content: String,
        attachments: [Attachment] = [],
        embeds: [Embed] = [],
        stickers: [StickerRef] = [],
        channelID: ChannelID? = nil,
        guildID: GuildID? = nil,
        messageID: MessageID? = nil,
        timestamp: Date? = nil
    ) {
        self.content = content
        self.attachments = attachments
        self.embeds = embeds
        self.stickers = stickers
        self.channelID = channelID
        self.guildID = guildID
        self.messageID = messageID
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case content, attachments, embeds, stickers, channelID, guildID, messageID, timestamp
    }

    /// **Every field after the first three is read if present**: a forward
    /// written to the message cache before they existed still reads back.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(String.self, forKey: .content)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        embeds = try container.decodeIfPresent([Embed].self, forKey: .embeds) ?? []
        stickers = try container.decodeIfPresent([StickerRef].self, forKey: .stickers) ?? []
        channelID = try container.decodeIfPresent(ChannelID.self, forKey: .channelID)
        guildID = try container.decodeIfPresent(GuildID.self, forKey: .guildID)
        messageID = try container.decodeIfPresent(MessageID.self, forKey: .messageID)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
    }
}

extension EmojiRef {
    /// Reads `messageToken` back into a reference.
    ///
    /// The inverse of `messageToken`, and it exists because the expression
    /// picker speaks in tokens — a pick is "what to type into a draft" — while
    /// a reaction is addressed by name and id. Parsing the token back is one
    /// scan of at most a few dozen bytes; the alternative is a second field on
    /// every one of the two thousand items the picker builds.
    ///
    /// **Split by hand, not by a regex.** A Swift regex literal is re-parsed on
    /// every call — `INVARIANTS.md` §2 — and this runs on a pick.
    public init?(messageToken token: String) {
        guard token.hasPrefix("<"), token.hasSuffix(">") else {
            guard !token.isEmpty else { return nil }
            self.init(name: token)
            return
        }
        let body = token.dropFirst().dropLast()
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        // `a:name:id` when animated, `:name:id` when not — the leading field is
        // empty for a still emoji, which is why empty subsequences are kept.
        guard parts.count == 3, let id = EmojiID(parts[2]), !parts[1].isEmpty else {
            return nil
        }
        self.init(id: id, name: String(parts[1]), isAnimated: parts[0] == "a")
    }
}


/// The command a message is answering, and who ran it.
///
/// **One type for slash commands and activity launches alike.** Both are
/// interactions on the wire; the captured launch carries
/// `interaction_metadata: {id, type: 2, user, name: "launch", command_type: 4}`
/// beside a legacy `interaction` with the same name and user. The newer key is
/// preferred and the older one is the fallback — Discord has been removing the
/// latter, and a client reading only it loses the header when it goes.
public struct MessageInteraction: Hashable, Sendable, Codable {
    public var userID: UserID
    /// The command's name, drawn in the chip: `launch`, `ban`, `play`.
    public var name: String
    /// `1` chat input, `2` user, `3` message, `4` primary entry point. Kept raw
    /// so a kind this client has no name for still draws its header.
    public var commandType: Int

    public init(userID: UserID, name: String, commandType: Int) {
        self.userID = userID
        self.name = name
        self.commandType = commandType
    }
}
