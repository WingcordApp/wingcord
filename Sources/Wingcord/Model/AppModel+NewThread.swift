import Foundation
import WingcordCore
import WingcordNet

// MARK: - Starting a thread

/// Discord's thread-creation sidebar (`SIDEBAR_CREATE_THREAD`): a new thread
/// being written beside the channel it will hang off.
struct NewThreadRequest: Identifiable, Hashable, Sendable {
    var parentID: ChannelID
    /// The message it hangs off, when it was started from one.
    var messageID: MessageID?
    /// Discord's `location` for the create — "Plus Button", "Message",
    /// "Thread Browser Toolbar", "Thread Browser Empty State".
    var location: String
    /// What the channel's composer held when the panel opened. Discord moves
    /// it into the thread's first message rather than leaving it behind.
    var seedText: String

    var id: String { "\(parentID.rawValue)-\(messageID?.rawValue ?? 0)" }
}

/// What the New Thread panel shows, resolved from the store.
struct NewThreadForm {
    /// "Thread Name (Optional)" off a message, where Discord names it for you.
    var isFromMessage: Bool
    var privateMode: ThreadCreation.PrivateMode
    /// Discord's placeholder: the name an unnamed thread gets, or "New Thread".
    var namePlaceholder: String
    /// The message it hangs off: who wrote it, and its words.
    var messageAuthor: String?
    var messageText: String?
}

/// Why a thread was not started, in Discord's words, under the field at fault.
struct NewThreadRefusal: Equatable {
    var nameError: String?
    var messageError: String?

    var isEmpty: Bool { nameError == nil && messageError == nil }
}

extension AppModel {

    /// Discord's Create Thread on the composer's + and in the Threads popout:
    /// a public or a private thread may be started here.
    func canStartThread(in channelID: ChannelID) -> Bool {
        guard let channel = channelIndex[channelID], guildPreview?.guildID != channel.guildID else { return false }
        return ThreadCreation.canCreate(in: channel, permissions: permissionGate.permissions(in: channelID))
    }

    /// Opens Discord's New Thread beside the channel — in the column a thread
    /// opens in, closing whatever thread was there, as Discord's sidebar does.
    ///
    /// **The composer's words move with it** (`747926`'s `Tv`): whatever was
    /// being typed in the channel becomes the thread's first message. Closing
    /// the panel unsent puts them back.
    func startThread(in parentID: ChannelID, from messageID: MessageID? = nil, location: String) {
        guard let parent = channelIndex[parentID] else { return }
        let permissions = permissionGate.permissions(in: parentID)
        if let messageID {
            guard let message = message(messageID, in: parentID),
                  ThreadCreation.canCreatePublic(in: parent, permissions: permissions, from: message)
            else { return }
        } else {
            guard canStartThread(in: parentID) else { return }
        }
        dismissMessageSurfaces()
        if selectedChannelID != parentID { selectChannel(parentID) }
        selectedThreadID = nil
        let seed = messages(in: parentID)?.draft ?? ""
        if !seed.isEmpty { mutateBox(parentID) { $0.draft = "" } }
        newThread = NewThreadRequest(parentID: parentID, messageID: messageID, location: location, seedText: seed)
    }

    func closeNewThread() {
        guard newThread != nil else { return }
        newThread = nil
    }

    /// The panel went away unsent — closed, replaced by a thread, or left
    /// behind with its channel. Its words go back to the channel's composer,
    /// if that is still empty, so nothing typed is lost.
    func abandonNewThread(_ request: NewThreadRequest, unsentText text: String) {
        if newThread == request { newThread = nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mutateBox(request.parentID) { box in
            if box.draft.isEmpty { box.draft = text }
        }
    }

    func newThreadForm(for request: NewThreadRequest) -> NewThreadForm? {
        guard let parent = channelIndex[request.parentID] else { return nil }
        let message = request.messageID.flatMap { message($0, in: request.parentID) }
        let derived = defaultThreadName(for: request)
        return NewThreadForm(
            isFromMessage: request.messageID != nil,
            // A thread off a message is public: Discord offers no box there.
            privateMode: request.messageID == nil
                ? ThreadCreation.privateMode(in: parent, permissions: permissionGate.permissions(in: parent.id))
                : .disabled,
            namePlaceholder: derived.isEmpty ? "New Thread" : derived,
            messageAuthor: message.map { authorName(of: $0) },
            messageText: message.map { readableText($0.content) }
        )
    }

    /// Discord's name for a thread nobody named — see
    /// `ThreadCreation.defaultName`. Empty when not started from a message.
    func defaultThreadName(for request: NewThreadRequest) -> String {
        guard let messageID = request.messageID, let message = message(messageID, in: request.parentID) else {
            return ""
        }
        return ThreadCreation.defaultName(
            embedTitle: message.embeds.first?.title,
            pollQuestion: message.poll?.question,
            text: readableText(message.content)
        )
    }

    /// Starts the thread, opens it, and sends its first message — Discord's
    /// order. Discord's refusals under the field they belong to, or nil once
    /// it is made.
    func submitNewThread(_ request: NewThreadRequest, name: String, isPrivate: Bool, text: String) async -> NewThreadRefusal? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var refusal = NewThreadRefusal()
        if request.messageID == nil, trimmedName.isEmpty { refusal.nameError = "Thread Name is required" }
        if trimmedText.isEmpty { refusal.messageError = "Starter Message is required" }
        guard refusal.isEmpty else { return refusal }
        guard let parent = channelIndex[request.parentID], let form = newThreadForm(for: request) else {
            return NewThreadRefusal(messageError: "An error occurred, please try again.")
        }

        let makesPrivate = switch form.privateMode {
        case .disabled: false
        case .enabled: isPrivate
        case .privateOnly: true
        }
        let derived = defaultThreadName(for: request)
        let finalName = !trimmedName.isEmpty ? trimmedName : (derived.isEmpty ? "Thread" : derived)
        do {
            let thread = try await sessionController.rest.createThread(
                in: request.parentID,
                from: request.messageID,
                name: finalName,
                kind: ThreadCreation.kind(isPrivate: makesPrivate, parent: parent),
                autoArchiveMinutes: parent.defaultAutoArchiveDuration ?? 4320,
                location: request.location
            )
            // Its maker is in it, as the gateway will say a moment later.
            let membership = currentUserID.map { ThreadMember(id: thread.id, userID: $0, joinedAt: .now) }
            applyThreadUpsert(thread, membership: membership)
            if newThread == request { newThread = nil }
            openThread(thread.id)
            sessionController.send(trimmedText, in: thread.id, replyingTo: nil)
            return nil
        } catch DiscordREST.Failure.api(_, 50035?, _) {
            // Discord's invalid form body, which its form reads as the name.
            return NewThreadRefusal(nameError: "Thread Name is required")
        } catch DiscordREST.Failure.api(_, _, let message?) where !message.isEmpty {
            return NewThreadRefusal(messageError: message)
        } catch {
            return NewThreadRefusal(messageError: "An error occurred, please try again.")
        }
    }

    /// A message's words as people read them — Discord's `unparse`: mentions
    /// become names and custom emoji their `:name:`.
    func readableText(_ content: String) -> String {
        guard content.contains("<") else { return content }
        var result = ""
        var rest = Substring(content)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            result += rest[..<open]
            let token = rest[rest.index(after: open)..<close]
            result += readable(token) ?? "<\(token)>"
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    private func readable(_ token: Substring) -> String? {
        func id(_ digits: Substring) -> UInt64? { UInt64(digits) }
        if token.hasPrefix("@&"), let roleID = id(token.dropFirst(2)) {
            let role = roles.values.lazy.compactMap { $0[RoleID(rawValue: roleID)] }.first
            return role.map { "@\($0.name)" }
        }
        if token.hasPrefix("@"), let userID = id(token.dropFirst(token.hasPrefix("@!") ? 2 : 1)) {
            return users[UserID(rawValue: userID)].map { "@\($0.preferredName)" }
        }
        if token.hasPrefix("#"), let channelID = id(token.dropFirst()) {
            return channelIndex[ChannelID(rawValue: channelID)].map { "#\(displayName(of: $0))" }
        }
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 3, parts[0].isEmpty || parts[0] == "a" { return ":\(parts[1]):" }
        return nil
    }

    private func authorName(of message: Message) -> String {
        let user = users[message.authorID]
        let member = channelIndex.guildID(of: message.channelID).flatMap { members[$0]?[message.authorID] }
        return member?.resolvedName(user: user) ?? user?.preferredName ?? ""
    }
}
