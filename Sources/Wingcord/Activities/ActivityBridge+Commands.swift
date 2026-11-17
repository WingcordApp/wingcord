import AppKit
import UniformTypeIdentifiers
import WingcordCore

// MARK: - The rest of the Embedded App SDK (docs/ACTIVITIES-CALLS-PICKER.md, decision 7)
//
// Each answer is shaped by Discord's own schema for it (web.js, 2026-11-17:
// the `embeddedAppSDK: !0` table) and each rule is its handler's:
//
// - OPEN_INVITE_DIALOG: no args, empty answer; an invite with `target_type`
//   2 and the app, sent through the share sheet.
// - SHARE_LINK: `{message, custom_id?, link_id?}` →
//   `{success, didCopyLink, didSendMessage}`; the link is the activity's
//   (`/activities/{app}`) with the referrer and the app's ids.
// - OPEN_SHARE_MOMENT_DIALOG: `{mediaUrl}`, which must be on Discord's CDN.
// - INITIATE_IMAGE_UPLOAD: a picture (PNG, JPEG, GIF) → `{image_url}`.
// - GET_RELATIONSHIPS: only with `relationships.read`; `{relationships:
//   [{type, user, presence: {status, activity}}]}`.
// - GET_USER `{id}` → a user or null; OPEN_USER_PROFILE `{user_id}` →
//   `{opened}`; REQUEST_PROXY_TICKET_REFRESH → `{ticket}`.

extension ActivityBridge {

    func openInviteDialog(_ frame: ActivityFrameMessage) {
        let location = activity.instance.location
        guard location.guildID != nil else {
            // A direct message's call has its people already; Discord's
            // dialog there invites into the DM, which an invite link can't.
            refuse(frame, code: .invalidCommand, message: "Invites need a server channel.")
            return
        }
        Task {
            do {
                let link = try await model.sessionController.rest.createActivityInvite(
                    in: location.channelID, application: activity.applicationID
                )
                model.activityShareRequest = ActivityShareRequest(
                    kind: .invite, applicationID: activity.applicationID, appName: activity.name,
                    iconURL: activity.iconURL, link: link
                )
                reply(to: frame, data: [:])
            } catch {
                Self.trace("invite failed: \(error)")
                refuse(frame, code: .invalidPermissions, message: "You can't create invites here.")
            }
        }
    }

    func shareLink(_ frame: ActivityFrameMessage) {
        guard let message = frame.arguments["message"] as? String else {
            refuse(frame, code: .invalidCommand, message: "A message is required.")
            return
        }
        var components = URLComponents(string: "https://discord.com/activities/\(activity.applicationID.rawValue)")
        var query: [URLQueryItem] = []
        if let me = model.currentUserID { query.append(URLQueryItem(name: "referrer_id", value: String(me.rawValue))) }
        if let customID = frame.arguments["custom_id"] as? String, !customID.isEmpty {
            query.append(URLQueryItem(name: "custom_id", value: customID))
        }
        if let linkID = frame.arguments["link_id"] as? String, !linkID.isEmpty {
            query.append(URLQueryItem(name: "link_id", value: linkID))
        }
        components?.queryItems = query.isEmpty ? nil : query
        guard let link = components?.url?.absoluteString else {
            refuse(frame, code: .invalidCommand, message: "That link can't be made.")
            return
        }
        model.activityShareRequest = ActivityShareRequest(
            kind: .link(message: String(message.prefix(1000))),
            applicationID: activity.applicationID, appName: activity.name, iconURL: activity.iconURL,
            link: link,
            finish: { [weak self] didCopy, didSend in
                self?.reply(to: frame, data: [
                    "success": didCopy || didSend, "didCopyLink": didCopy, "didSendMessage": didSend,
                ])
            }
        )
    }

    func shareMoment(_ frame: ActivityFrameMessage) {
        guard let text = frame.arguments["mediaUrl"] as? String,
              let url = URL(string: text),
              Self.isDiscordCDN(url)
        else {
            refuse(frame, code: .invalidPayload, message: "mediaUrl must be a Discord CDN url")
            return
        }
        model.activityShareRequest = ActivityShareRequest(
            kind: .moment(imageURL: url), applicationID: activity.applicationID, appName: activity.name,
            iconURL: activity.iconURL, link: url.absoluteString
        )
        reply(to: frame, data: [:])
    }

    func uploadImage(_ frame: ActivityFrameMessage) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for \(activity.name)"
        panel.prompt = "Upload"
        guard panel.runModal() == .OK, let file = panel.url,
              let data = try? Data(contentsOf: file)
        else {
            refuse(frame, code: .unknown, message: "Upload canceled")
            return
        }
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "image/png"
        Task {
            do {
                let url = try await model.sessionController.rest.uploadActivityImage(
                    application: activity.applicationID,
                    channelID: activity.instance.location.channelID,
                    data: data, filename: file.lastPathComponent, contentType: type
                )
                reply(to: frame, data: ["image_url": url.absoluteString])
            } catch {
                Self.trace("upload failed: \(error)")
                refuse(frame, code: .unknown, message: "Failed to upload image")
            }
        }
    }

    func relationships(_ frame: ActivityFrameMessage) {
        guard grantedScopes.contains("relationships.read") else {
            refuse(frame, code: .invalidPermissions, message: "Missing Permissions")
            return
        }
        let rows: [[String: Any]] = model.relationships.compactMap { userID, kind in
            guard kind != .none, let user = model.users[userID] else { return nil }
            let status = model.presences[userID]?.status ?? .offline
            return [
                "type": kind.rawValue,
                "user": Self.payload(for: user),
                "presence": ["status": status == .unknown ? "offline" : status.rawValue, "activity": NSNull()],
            ]
        }
        reply(to: frame, data: ["relationships": rows])
    }

    func getUser(_ frame: ActivityFrameMessage) {
        let id = (frame.arguments["id"] as? String).flatMap(UserID.init)
        reply(to: frame, data: id.flatMap { model.users[$0] }.map(Self.payload(for:)) ?? NSNull())
    }

    func openUserProfile(_ frame: ActivityFrameMessage) {
        guard let id = (frame.arguments["user_id"] as? String).flatMap(UserID.init), model.users[id] != nil else {
            reply(to: frame, data: ["opened": false])
            return
        }
        model.openProfile(id, anchor: .zero, depth: .full)
        reply(to: frame, data: ["opened": true])
    }

    func refreshProxyTicket(_ frame: ActivityFrameMessage) {
        Task {
            do {
                let ticket = try await model.sessionController.rest.activityProxyTicket(
                    application: activity.applicationID, channelID: activity.instance.location.channelID
                )
                reply(to: frame, data: ["ticket": ticket])
            } catch {
                refuse(frame, code: .unknown, message: "Failed to create proxy ticket")
            }
        }
    }

    // MARK: Events on subscribe

    /// What an app hears the moment it subscribes, and after.
    func subscribed(to event: String) {
        switch event {
        case "CURRENT_USER_UPDATE":
            if let me = currentUserPayload { dispatch(event: event, data: me) }
        case "THERMAL_STATE_UPDATE":
            dispatch(event: event, data: ["thermal_state": Self.thermalState])
            guard thermalObserver == nil else { return }
            thermalObserver = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.subscriptions.contains("THERMAL_STATE_UPDATE") else { return }
                    self.dispatch(event: "THERMAL_STATE_UPDATE", data: ["thermal_state": Self.thermalState])
                }
            }
        case "SPEAKING_START", "SPEAKING_STOP":
            startSpeakingWatch()
        default:
            break
        }
    }

    // MARK: Who's talking in the call

    /// Follows the call's speaking set while the app listens: a change is a
    /// few a sentence (`AppModel.speakingUserIDs`), not one per packet.
    private func startSpeakingWatch() {
        guard !watchesSpeaking else { return }
        watchesSpeaking = true
        lastSpeakers = currentSpeakers()
        observeSpeaking()
    }

    private func observeSpeaking() {
        withObservationTracking {
            _ = model.speakingUserIDs
            _ = model.isSelfSpeaking
            _ = model.connectedVoiceChannelID
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.watchesSpeaking else { return }
                self.speakingChanged()
                self.observeSpeaking()
            }
        }
    }

    /// Only the activity's own call: an app in one channel hears nothing of
    /// another.
    private func currentSpeakers() -> Set<UserID> {
        guard model.connectedVoiceChannelID == activity.instance.location.channelID else { return [] }
        var speakers = model.speakingUserIDs
        if model.isSelfSpeaking, let me = model.currentUserID { speakers.insert(me) }
        return speakers
    }

    private func speakingChanged() {
        let now = currentSpeakers()
        let channel = activity.instance.location.channelID.description
        if subscriptions.contains("SPEAKING_START") {
            for userID in now.subtracting(lastSpeakers) {
                dispatch(event: "SPEAKING_START", data: ["user_id": userID.description, "channel_id": channel])
            }
        }
        if subscriptions.contains("SPEAKING_STOP") {
            for userID in lastSpeakers.subtracting(now) {
                dispatch(event: "SPEAKING_STOP", data: ["user_id": userID.description, "channel_id": channel])
            }
        }
        lastSpeakers = now
    }

    /// The SDK's `ThermalStateTypeObject`: nominal 0, fair 1, serious 2, critical 3.
    private static var thermalState: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 0
        }
    }

    private static func isDiscordCDN(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host() else { return false }
        return ["cdn.discordapp.com", "media.discordapp.net", "images-ext-1.discordapp.net"].contains(host)
            || host.hasSuffix(".discordapp.net")
    }
}
