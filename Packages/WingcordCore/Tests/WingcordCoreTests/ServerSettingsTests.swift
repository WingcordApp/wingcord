import Foundation
import Testing
@testable import WingcordCore

/// The server management surface's arithmetic.
///
/// Every test here covers a place where a *plausible* implementation is wrong
/// and the failure is silent. None of them is a smoke test: a settings window
/// that draws is not evidence that the switch labelled "send a welcome message"
/// is not, in fact, suppressing it.
@Suite("Server settings")
struct ServerSettingsTests {

    // MARK: System channel flags
    //
    // Every bit on the wire is a SUPPRESSION and every switch on the page is a
    // positive. The whole point of `sends(_:)` is that the inversion is written
    // once — and the reason it is worth a test is that on a server which has
    // never touched these, the flags are zero and a client that got the polarity
    // backwards looks correct.

    @Test("A zero flag set sends every system message")
    func flagsDefaultToSending() {
        let flags = SystemChannelFlags(rawValue: 0)
        for entry in SystemChannelFlags.engagementOrder {
            #expect(flags.sends(entry.flag), "\(entry.label) should be on by default")
        }
    }

    @Test("Turning a message off sets its bit, and only its bit")
    func flagsSetOneBit() {
        let flags = SystemChannelFlags(rawValue: 0)
            .setting(.suppressPremiumSubscriptions, sending: false)
        #expect(flags.contains(.suppressPremiumSubscriptions))
        #expect(!flags.sends(.suppressPremiumSubscriptions))
        // The other three are untouched, which is what a page that saves all
        // four together depends on.
        #expect(flags.sends(.suppressJoinNotifications))
        #expect(flags.sends(.suppressJoinNotificationReplies))
        #expect(flags.sends(.suppressGuildReminderNotifications))
    }

    @Test("Turning one back on clears only its own bit")
    func flagsClearOneBit() {
        let all = SystemChannelFlags(rawValue: 0b1111)
        let flags = all.setting(.suppressJoinNotifications, sending: true)
        #expect(flags.sends(.suppressJoinNotifications))
        #expect(!flags.sends(.suppressPremiumSubscriptions))
        #expect(flags.rawValue == 0b1110)
    }

    @Test("The engagement page offers four switches, in Discord's order")
    func flagsOrder() {
        let order = SystemChannelFlags.engagementOrder.map(\.flag)
        #expect(order == [
            .suppressJoinNotifications,
            // The sticker prompt qualifies the welcome message above it and is
            // drawn under it, though its bit is 1 << 3 rather than 1 << 1.
            .suppressJoinNotificationReplies,
            .suppressPremiumSubscriptions,
            .suppressGuildReminderNotifications,
        ])
    }

    // MARK: Content level
    //
    // The Age-Restricted switch writes 3 and 0, not 1 and 0. A `Bool` at the
    // model layer is what puts that surprise in whichever encoder was written
    // last.

    @Test("Age restriction is 3 and 0, not 1 and 0")
    func contentLevelValues() {
        #expect(ContentLevel.ageRestricted.rawValue == 3)
        #expect(ContentLevel.default.rawValue == 0)
        #expect(ContentLevel(rawValue: 3) == .ageRestricted)
        #expect(ContentLevel(rawValue: 0) == .default)
        #expect(ContentLevel.ageRestricted.isAgeRestricted)
        #expect(!ContentLevel.default.isAgeRestricted)
    }

    @Test("An unrecognised content level keeps its number")
    func contentLevelUnknown() {
        let level = ContentLevel(rawValue: 7)
        #expect(level == .unrecognised(7))
        // And survives a round trip, which is the point: a save must not lower
        // a gate this client cannot name.
        #expect(level.rawValue == 7)
    }

    // MARK: Enumerations that must not fold
    //
    // Every one of these is written back. Folding an unknown value into a
    // default would silently *lower* a server's setting the first time somebody
    // saved an unrelated field on the same page.

    @Test("Unrecognised levels round-trip rather than folding to a default")
    func levelsRoundTrip() {
        #expect(VerificationLevel(rawValue: 99).rawValue == 99)
        #expect(NotificationLevel(rawValue: 42).rawValue == 42)
        #expect(ExplicitContentFilter(rawValue: 8).rawValue == 8)
        // And the known ones still round-trip, which is the other half.
        for level in VerificationLevel.selectable {
            #expect(VerificationLevel(rawValue: level.rawValue) == level)
        }
        for filter in ExplicitContentFilter.selectable {
            #expect(ExplicitContentFilter(rawValue: filter.rawValue) == filter)
        }
    }

    // MARK: Access mode
    //
    // Three routes behind one segmented control, resolved in one place.

    @Test("Discovery wins over an application form")
    func accessModeDiscovery() {
        let mode = GuildAccessMode(features: ["COMMUNITY", "DISCOVERABLE"], hasJoinForm: true)
        #expect(mode == .discoverable)
    }

    @Test("A form without discovery is Apply to Join")
    func accessModeApply() {
        #expect(GuildAccessMode(features: ["COMMUNITY"], hasJoinForm: true) == .applyToJoin)
    }

    @Test("Neither is Invite Only")
    func accessModeInvite() {
        #expect(GuildAccessMode(features: [], hasJoinForm: false) == .inviteOnly)
        #expect(GuildAccessMode(features: ["COMMUNITY"], hasJoinForm: false) == .inviteOnly)
    }

    // MARK: Discovery requirements
    //
    // "Cannot tell yet" is the ordinary answer for a small server, and drawing
    // it as a failure tells most servers they failed something unmeasured.

    @Test("A pending health score is a caution, not a failure")
    func discoveryPending() {
        let requirements = DiscoveryRequirements(
            guildID: GuildID(rawValue: 1),
            isHealthy: false,
            isHealthScorePending: true,
            minimumSize: 1000,
            minimumAge: 56
        )
        let health = requirements.requirements.first { $0.id == "health" }
        #expect(health?.outcome == .pending)
    }

    @Test("A measured and failed health score is a failure")
    func discoveryUnhealthy() {
        let requirements = DiscoveryRequirements(
            guildID: GuildID(rawValue: 1),
            isHealthy: false,
            isHealthScorePending: false
        )
        #expect(requirements.requirements.first { $0.id == "health" }?.outcome == .unmet)
    }

    // MARK: Slots

    @Test("Expression budgets follow the boost tier")
    func slots() {
        #expect(ExpressionSlots.emoji(premiumTier: 0) == 50)
        #expect(ExpressionSlots.emoji(premiumTier: 3) == 250)
        #expect(ExpressionSlots.soundboard(premiumTier: 0) == 8)
        #expect(ExpressionSlots.stickers(premiumTier: 2) == 30)
        // An unknown tier reads as the free one rather than trapping.
        #expect(ExpressionSlots.emoji(premiumTier: 9) == 50)
    }

    // MARK: Image data
    //
    // The `data:` URI is the whole prefix, not the bare base64 — getting it
    // wrong answers a 400 that names the field rather than the encoding.

    @Test("Image data carries the whole data URI prefix")
    func imageDataURI() {
        let image = ImageData.png(Data([0xDE, 0xAD]))
        #expect(image.dataURI == "data:image/png;base64,3q0=")
        #expect(ImageData.ogg(Data()).dataURI.hasPrefix("data:audio/ogg;base64,"))
    }

    // MARK: Permissions

    @Test("Permissions go out as a decimal string")
    func permissionsAPIString() {
        // The @everyone value from the captured guild.
        let permissions = Permissions(string: "2222085186768449")
        #expect(permissions.apiString == "2222085186768449")
    }

    @Test("The catalog names every permission it can draw, and no more")
    func catalogKnownBits() {
        #expect(PermissionCatalog.known.contains(.administrator))
        #expect(PermissionCatalog.known.contains(.pinMessages))
        #expect(PermissionCatalog.known.contains(.createEvents))
        // 1 << 47 is retired and deliberately absent.
        #expect(!PermissionCatalog.known.contains(Permissions(rawValue: 1 << 47)))
    }

    /// **The one that matters most on the roles page.**
    ///
    /// The editor writes the whole bitfield back. A permission newer than this
    /// build must survive, or every role anybody renames quietly loses it — and
    /// six flags were missing from this client until a capture arrived, so this
    /// is not hypothetical.
    @Test("A permission the catalog cannot draw survives an edit")
    func unknownPermissionBitsSurvive() {
        let future = Permissions(rawValue: 1 << 60)
        let held: Permissions = [.sendMessages, .viewChannel, future]

        let unknown = PermissionCatalog.unknownBits(in: held)
        #expect(unknown.contains(future))
        #expect(!unknown.contains(.sendMessages))

        // What the sheet does on save: the drawn switches, plus the bits it
        // could not draw.
        var edited: Permissions = [.viewChannel]
        edited.formUnion(unknown)
        #expect(edited.contains(future))
        #expect(!edited.contains(.sendMessages))
    }

    @Test("A role holding only known permissions has no unknown bits")
    func noUnknownBits() {
        #expect(PermissionCatalog.unknownBits(in: [.sendMessages, .banMembers]).isEmpty)
    }

    @Test("Searching the catalog drops empty groups")
    func catalogSearch() {
        let groups = PermissionCatalog.groups(matching: "webhook")
        #expect(!groups.isEmpty)
        #expect(groups.allSatisfy { !$0.entries.isEmpty })
        #expect(groups.flatMap(\.entries).contains { $0.permission == .manageWebhooks })
        #expect(PermissionCatalog.groups(matching: "").count == PermissionCatalog.groups.count)
    }

    // MARK: Roles

    @Test("@everyone is recognised by id, not by name")
    func everyoneRole() {
        let guildID = GuildID(rawValue: 42)
        let everyone = Role(id: RoleID(rawValue: 42), name: "renamed by somebody")
        let other = Role(id: RoleID(rawValue: 43), name: "@everyone")
        #expect(everyone.isEveryone(in: guildID))
        #expect(!other.isEveryone(in: guildID))
    }

    @Test("A managed role is not editable")
    func managedRole() {
        #expect(!Role(id: RoleID(rawValue: 1), name: "Bot", isManaged: true).isEditable)
        #expect(Role(id: RoleID(rawValue: 1), name: "Mods").isEditable)
    }

    @Test("Zero is no colour, not black")
    func roleColourZero() {
        #expect(Role(id: RoleID(rawValue: 1), name: "x", colorValue: 0).displayColorValue == nil)
        #expect(Role(id: RoleID(rawValue: 1), name: "x", colorValue: 1).displayColorValue == 1)
    }

    @Test("A gradient is recognised by its extra stops")
    func roleGradient() {
        #expect(!RoleColors(primary: 0x00FF00).isGradient)
        #expect(RoleColors(primary: 0x00FF00, secondary: 0xFF0000).isGradient)
    }

    // MARK: Invites

    @Test("An invite with no maximum reads as unlimited")
    func inviteUnlimited() {
        #expect(GuildInvite(id: "abc", maxUses: 0).isUnlimitedUses)
        #expect(!GuildInvite(id: "abc", maxUses: 5).isUnlimitedUses)
    }

    @Test("Expiry is computed against a given instant, not stored")
    func inviteExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expired = GuildInvite(id: "a", expiresAt: now.addingTimeInterval(-1))
        let live = GuildInvite(id: "b", expiresAt: now.addingTimeInterval(60))
        let never = GuildInvite(id: "c", expiresAt: nil)
        #expect(expired.hasExpired(asOf: now))
        #expect(!live.hasExpired(asOf: now))
        #expect(!never.hasExpired(asOf: now))
    }

    // MARK: Templates

    @Test("A template is dirty only on an explicit true")
    func templateDirty() {
        // Null is "in step" and there is no `false` on the wire, so the Sync
        // control is offered on `true` alone rather than on "not false".
        #expect(GuildTemplate(id: "a", name: "x", isDirty: nil).isDirty != true)
        #expect(GuildTemplate(id: "a", name: "x", isDirty: true).isDirty == true)
    }

    // MARK: Members

    @Test("A join source of nothing reads as Unknown, never blank")
    func joinSourceUnknown() {
        let source = GuildMemberRow.JoinSource(rawValue: nil, code: nil, inviterID: nil)
        #expect(source == .unspecified)
        #expect(source.title == "Unknown")
    }

    @Test("An invite join carries its code and its inviter")
    func joinSourceInvite() {
        let inviter = UserID(rawValue: 7)
        let source = GuildMemberRow.JoinSource(rawValue: 5, code: "DbSUmAEB6", inviterID: inviter)
        #expect(source == .invite(code: "DbSUmAEB6", inviterID: inviter))
        #expect(source.title == "Invite DbSUmAEB6")
        #expect(source.inviterID == inviter)
    }

    @Test("A past timeout is not a timeout")
    func memberTimeout() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let past = GuildMemberRow(
            id: UserID(rawValue: 1), username: "a",
            timedOutUntil: now.addingTimeInterval(-1)
        )
        let current = GuildMemberRow(
            id: UserID(rawValue: 1), username: "a",
            timedOutUntil: now.addingTimeInterval(60)
        )
        #expect(!past.isTimedOut(asOf: now))
        #expect(current.isTimedOut(asOf: now))
    }

    @Test("A nickname beats a display name beats a username")
    func memberName() {
        #expect(GuildMemberRow(
            id: UserID(rawValue: 1), username: "u", displayName: "d", nickname: "n"
        ).name == "n")
        #expect(GuildMemberRow(
            id: UserID(rawValue: 1), username: "u", displayName: "d"
        ).name == "d")
        #expect(GuildMemberRow(id: UserID(rawValue: 1), username: "u").name == "u")
    }
}

// MARK: - Events

@Suite("Scheduled events")
struct ScheduledEventTests {

    /// Wednesday 9 September 2026, which is the date in the captured event and
    /// in the Event Frequency menu's own labels — "Weekly on Wednesday",
    /// "Annually on Sep 09".
    private var wednesday: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 9
        components.hour = 12
        return Calendar.current.date(from: components)!
    }

    // MARK: Location
    //
    // Three wire fields, one enum. The capture sends `channel_id: null`
    // *explicitly* beside a populated location, so the mapping has to be exact
    // in both directions.

    @Test("An external event has a location and no channel")
    func externalLocation() {
        let location = ScheduledEvent.Location(
            entityType: 3, channelID: nil, location: "somewhere"
        )
        #expect(location == .external("somewhere"))
        #expect(location.entityType == 3)
        #expect(location.channelID == nil)
        #expect(location.externalLocation == "somewhere")
    }

    @Test("A voice event has a channel and no location")
    func voiceLocation() {
        let channel = ChannelID(rawValue: 99)
        let location = ScheduledEvent.Location(entityType: 2, channelID: channel, location: nil)
        #expect(location == .voice(channel))
        #expect(location.entityType == 2)
        #expect(location.channelID == channel)
        #expect(location.externalLocation == nil)
    }

    @Test("A channel event with no channel is not a channel event")
    func locationWithoutChannel() {
        // Discord should never send this, and if it does, silently treating it
        // as external would put an empty address on the card.
        let location = ScheduledEvent.Location(entityType: 1, channelID: nil, location: nil)
        #expect(location == .unrecognised(1))
        #expect(!location.isEditable)
    }

    @Test("An unrecognised entity type keeps its number and is not editable")
    func unrecognisedLocation() {
        let location = ScheduledEvent.Location(entityType: 9, channelID: nil, location: nil)
        #expect(location.entityType == 9)
        #expect(!location.isEditable)
    }

    // MARK: Status

    @Test("Only a scheduled or active event can still be acted on")
    func eventStatus() {
        #expect(ScheduledEvent.Status(rawValue: 1).isLive)
        #expect(ScheduledEvent.Status(rawValue: 2).isLive)
        #expect(!ScheduledEvent.Status(rawValue: 3).isLive)
        #expect(!ScheduledEvent.Status(rawValue: 4).isLive)
        // An unknown status is not offered edit controls either — guessing
        // "live" is the direction that produces a 400 on a press.
        #expect(!ScheduledEvent.Status(rawValue: 77).isLive)
        #expect(ScheduledEvent.Status(rawValue: 77).rawValue == 77)
    }

    // MARK: Recurrence
    //
    // The weekday conversion is the arithmetic this type exists to contain:
    // `Calendar` numbers Sunday 1…Saturday 7, Discord numbers Monday 0…Sunday 6.

    @Test("Wednesday is Calendar 4 and Discord 2")
    func weekdayConversion() {
        #expect(Calendar.current.component(.weekday, from: wednesday) == 4)
        #expect(Recurrence.discordWeekday(wednesday) == 2)
    }

    @Test("Every weekday of a week maps across without collision")
    func weekdayConversionCoversTheWeek() {
        var seen: Set<Int> = []
        for offset in 0..<7 {
            let day = wednesday.addingTimeInterval(Double(offset) * 86_400)
            let discord = Recurrence.discordWeekday(day)
            #expect((0...6).contains(discord))
            seen.insert(discord)
        }
        #expect(seen.count == 7)
    }

    @Test("The ninth is the second occurrence of its weekday")
    func weekOfMonth() {
        #expect(Recurrence.weekOfMonth(wednesday) == 2)
    }

    @Test("Weekly and fortnightly differ only in the interval")
    func weeklyRules() {
        let weekly = Recurrence.weekly(weekday: 2)
        let biweekly = Recurrence.biweekly(weekday: 2)
        #expect(weekly.frequency == 2 && weekly.interval == 1 && weekly.byWeekday == [2])
        #expect(biweekly.frequency == 2 && biweekly.interval == 2 && biweekly.byWeekday == [2])
    }

    @Test("Weekdays is a five-day weekly rule")
    func weekdaysRule() {
        let rule = Recurrence.weekdays
        #expect(rule.frequency == 2)
        #expect(rule.interval == 1)
        #expect(rule.byWeekday == [0, 1, 2, 3, 4])
    }

    @Test("Monthly carries the nth weekday and nothing else")
    func monthlyRule() {
        let rule = Recurrence.monthly(week: 2, weekday: 2)
        #expect(rule.frequency == 1)
        #expect(rule.byWeekday == nil)
        #expect(rule.byNWeekday?.count == 1)
        #expect(rule.byNWeekday?[0].n == 2)
        #expect(rule.byNWeekday?[0].day == 2)
    }

    @Test("Annually carries a month and a day")
    func annuallyRule() {
        let rule = Recurrence.annually(month: 9, day: 9)
        #expect(rule.frequency == 0)
        #expect(rule.byMonth == [9])
        #expect(rule.byMonthDay == [9])
    }

    /// Every preset must survive the wire, or an event edited here loses its
    /// schedule.
    @Test("Every preset round-trips through the wire form")
    func recurrenceRoundTrip() {
        let presets: [Recurrence] = [
            .daily,
            .weekdays,
            .weekly(weekday: 2),
            .biweekly(weekday: 5),
            .monthly(week: 2, weekday: 2),
            .annually(month: 9, day: 9),
        ]
        for preset in presets {
            let decoded = Recurrence(
                frequency: preset.frequency,
                interval: preset.interval,
                byWeekday: preset.byWeekday,
                byNWeekday: preset.byNWeekday,
                byMonth: preset.byMonth,
                byMonthDay: preset.byMonthDay
            )
            #expect(decoded == preset, "\(preset) did not survive the round trip")
        }
    }

    @Test("A rule outside the six presets is kept rather than approximated")
    func recurrenceUnrecognised() {
        // Every third Tuesday and Friday is a legal rule Discord's own menu
        // cannot express either. Rounding it to "weekly on Tuesday" would
        // silently rewrite somebody's schedule on the next save.
        let rule = Recurrence(
            frequency: 2, interval: 3, byWeekday: [1, 4],
            byNWeekday: nil, byMonth: nil, byMonthDay: nil
        )
        #expect(rule == .unrecognised)
    }

    @Test("The menu offers six choices and never the unrecognised one")
    func recurrenceChoices() {
        let choices = Recurrence.choices(startingAt: wednesday)
        #expect(choices.count == 6)
        #expect(!choices.contains(.unrecognised))
        // Built from the event's own start date, which is what makes the labels
        // read correctly.
        #expect(choices.contains(.weekly(weekday: 2)))
        #expect(choices.contains(.monthly(week: 2, weekday: 2)))
        #expect(choices.contains(.annually(month: 9, day: 9)))
    }

    @Test("The labels name the event's own day and date")
    func recurrenceTitles() {
        #expect(Recurrence.weekly(weekday: 2).title(startingAt: wednesday) == "Weekly on Wednesday")
        #expect(
            Recurrence.biweekly(weekday: 2).title(startingAt: wednesday)
                == "Every other Wednesday"
        )
        #expect(
            Recurrence.monthly(week: 2, weekday: 2).title(startingAt: wednesday)
                == "Monthly on the second Wednesday"
        )
        #expect(Recurrence.daily.title(startingAt: wednesday) == "Every day")
        #expect(
            Recurrence.weekdays.title(startingAt: wednesday)
                == "Every weekday (Monday to Friday)"
        )
    }
}
