import SwiftUI
import WingcordCore
import WingcordNet

/// What the account lets other people send it.
///
/// **Every control here writes ONE field and sends only that field.**
/// `INVARIANTS.md` §1: a page sends the fields it owns, and Discord's own client
/// sends one per switch. A page that saved the whole value would send eleven
/// fields on every toggle — including this client's *reading* of the four that
/// are restrictions on the wire and permissions on the page, which is how a
/// setting nobody touched gets lowered.
///
/// **It is inert until it has loaded.** Writing needs the bytes a patch splices
/// into — see `MessagingPrivacyProto.patch` — and without them a write would
/// replace the reader's whole `text_and_images` message, which carries their
/// keyword filters and their collapsed picker sections, with one field.
struct MessagingPermissionsPane: View {
    @Environment(AppModel.self) private var model
    /// Which category's three rows are on screen. A tab, not a setting: all
    /// three exist on the account at once and this chooses which to look at.
    @State private var category: ContentFilterCategory = .explicit

    var body: some View {
        Group {
            contentFilters
            spamFilters
            directMessages
            friendRequests
            connectedGames
            blocked
        }
        .disabled(model.messagingPrivacyRaw == nil)
        .task { await model.sessionController.loadMessagingPrivacy() }
    }

    // MARK: Content filters

    private var contentFilters: some View {
        SettingsGroup("Content filters") {
            SettingsCard {
                CardHeaderRow(
                    title: "Sensitive media",
                    help: "How pictures Discord flags as sensitive are shown to you."
                )
                SettingsSegmentedControl(
                    selection: $category,
                    options: ContentFilterCategory.allCases.map {
                        .init($0, $0.title, symbolName: nil)
                    }
                )
                ForEach(ContentFilterSurface.allCases) { surface in
                    CardDivider()
                    SettingsFlyoutRow(
                        surface.title,
                        selection: redaction(surface),
                        options: surface.options,
                        title: \.title,
                        symbol: \.symbolName
                    )
                }
            }
            SettingsFootnote(category.summary, symbolName: "eye.trianglebadge.exclamationmark")

            SettingsCard {
                SettingsToggle(
                    title: "Age-restricted commands in direct messages",
                    help: "Lets people over 18 use commands marked age-restricted in DMs. "
                        + "Applies to every app.",
                    isOn: toggle(\.allowsAgeRestrictedCommands) { .ageRestrictedCommands($0) }
                )
                CardDivider()
                SettingsToggle(
                    title: "Age-restricted servers on iPhone",
                    help: "Lets you open age-restricted servers on an iPhone or iPad after "
                        + "joining them on a computer.",
                    isOn: toggle(\.allowsAgeRestrictedGuilds) { .ageRestrictedGuilds($0) }
                )
            }
        }
    }

    // MARK: Spam

    private var spamFilters: some View {
        SettingsGroup("Spam") {
            SettingsCard {
                SettingsFlyoutRow(
                    "Filter suspected spam",
                    help: "Filtered messages go to Message Requests instead of your inbox.",
                    selection: binding(\.spamFilter) { .spamFilter($0) },
                    options: DMSpamFilter.choices,
                    title: \.title,
                    detail: \.detail
                )
            }
        }
    }

    // MARK: Direct messages

    private var directMessages: some View {
        SettingsGroup("Direct messages") {
            SettingsCard {
                CardHeaderRow(
                    title: "New servers",
                    help: "What a server you join from now on starts out allowing."
                )
                SettingsToggle(
                    title: "Direct messages",
                    help: "Lets other members of a server message you.",
                    isOn: toggle(\.allowsDirectMessagesByDefault) {
                        .directMessagesByDefault($0)
                    }
                )
                CardDivider()
                SettingsToggle(
                    title: "Message requests",
                    help: "Holds messages from server members you may not know, so they "
                        + "arrive as a request rather than in your inbox.",
                    isOn: toggle(\.filtersMessageRequestsByDefault) {
                        .messageRequestsByDefault($0)
                    }
                )
            }
            SettingsFootnote(
                "Servers you\u{2019}re already in keep their own. Change one from its menu \u{203A} Privacy Settings.",
                symbolName: "building.2"
            )
        }
    }

    // MARK: Friend requests

    private var friendRequests: some View {
        SettingsGroup("Friend requests") {
            SettingsCard {
                CardHeaderRow(
                    title: "Who can add you",
                    help: "Turning all three off means nobody can send you a friend request."
                )
                ForEach(Array(FriendSourceFlags.sources.enumerated()), id: \.offset) { entry in
                    if entry.offset > 0 { CardDivider() }
                    SettingsToggle(
                        title: entry.element.title,
                        help: entry.element.detail,
                        isOn: source(entry.element.flag)
                    )
                }
                CardDivider()
                SettingsToggle(
                    title: "Show personalized messages",
                    help: "Shows the note somebody wrote with their request. If you accept, "
                        + "the message still arrives in your direct messages.",
                    // What's in force, Discord's fallback included, and the
                    // switch's first move writes the answer down.
                    isOn: Binding(
                        get: { model.showsFriendRequestNotes },
                        set: { newValue in
                            let previous = model.messagingPrivacy
                            model.messagingPrivacy.showsFriendRequestNotes = newValue
                            model.messagingPrivacy.hasFriendRequestNotesSetting = true
                            model.sessionController.writeMessagingPrivacy(
                                .friendRequestNotes(newValue), restoring: previous
                            )
                        }
                    )
                )
            }
        }
    }

    // MARK: Connected games

    private var connectedGames: some View {
        SettingsGroup("Connected games") {
            SettingsCard {
                SettingsToggle(
                    title: "Messages from connected games",
                    help: "Lets games that use Discord's social features message you here.",
                    isOn: toggle(\.allowsGameFriendDirectMessages) {
                        .gameFriendDirectMessages($0)
                    }
                )
            }
        }
    }

    // MARK: Blocked

    private var blocked: some View {
        SettingsGroup("Blocked") {
            SettingsCard {
                if model.blockedUserIDs.isEmpty {
                    SettingsValueRow(
                        title: "Blocked accounts",
                        value: "None",
                        help: "Someone you block can\u{2019}t message you or see your messages."
                    )
                } else {
                    CardHeaderRow(
                        title: "Blocked accounts",
                        help: "\(model.blockedUserIDs.count) "
                            + (model.blockedUserIDs.count == 1 ? "account" : "accounts")
                    )
                    // Discord's list has the way out beside each name, and so
                    // does this one: somebody blocked is hard to reach anywhere
                    // else, which is the point of blocking them.
                    ForEach(blockedPeople) { person in
                        CardDivider()
                        SettingsActionRow(person.name, help: person.handle, actionTitle: "Unblock") {
                            model.setBlocked(false, userID: person.id)
                        }
                    }
                }
            }
        }
    }

    /// The blocked accounts this client can name.
    ///
    /// **Sorted, and only the ones it has a user for.** A blocked id with no
    /// user object behind it is an account the session has never seen; drawing a
    /// row of blanks for it says less than leaving it out, and the count above
    /// is taken from the ids rather than from this so the two cannot disagree
    /// silently.
    private var blockedPeople: [BlockedPerson] {
        model.blockedUserIDs
            .compactMap { id in
                model.users[id].map {
                    BlockedPerson(id: id, name: $0.preferredName, handle: $0.handle)
                }
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct BlockedPerson: Identifiable {
        var id: UserID
        var name: String
        var handle: String
    }

    // MARK: Bindings

    /// A binding that writes through the store and puts itself back on refusal.
    ///
    /// **The optimistic move is in the getter's own value, not in a copy.** The
    /// pane holds no state of its own, so a write that fails and restores the
    /// model is the whole of the undo — there is no second copy to keep in step.
    private func binding<Value>(
        _ path: WritableKeyPath<MessagingPrivacy, Value>,
        _ change: @escaping (Value) -> MessagingPrivacyProto.Change
    ) -> Binding<Value> {
        Binding(
            get: { model.messagingPrivacy[keyPath: path] },
            set: { newValue in
                let previous = model.messagingPrivacy
                model.messagingPrivacy[keyPath: path] = newValue
                model.sessionController.writeMessagingPrivacy(
                    change(newValue), restoring: previous
                )
            }
        )
    }

    private func toggle(
        _ path: WritableKeyPath<MessagingPrivacy, Bool>,
        _ change: @escaping (Bool) -> MessagingPrivacyProto.Change
    ) -> Binding<Bool> {
        binding(path, change)
    }

    private func redaction(_ surface: ContentFilterSurface) -> Binding<ContentRedaction> {
        Binding(
            get: { model.messagingPrivacy[category][surface] },
            set: { newValue in
                let previous = model.messagingPrivacy
                model.messagingPrivacy[category][surface] = newValue
                model.sessionController.writeMessagingPrivacy(
                    .contentFilter(category, surface, newValue), restoring: previous
                )
            }
        )
    }

    /// One bit of the friend-source mask, as a switch.
    private func source(_ flag: FriendSourceFlags) -> Binding<Bool> {
        Binding(
            get: { model.messagingPrivacy.friendSources.contains(flag) },
            set: { isOn in
                var flags = model.messagingPrivacy.friendSources
                if isOn { flags.insert(flag) } else { flags.remove(flag) }
                let previous = model.messagingPrivacy
                model.messagingPrivacy.friendSources = flags
                model.sessionController.writeMessagingPrivacy(
                    .friendSources(flags), restoring: previous
                )
            }
        )
    }
}
