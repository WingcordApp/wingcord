import Foundation
import OSLog
import WebKit
import WingcordCore
import WingcordNet

/// The RPC server an activity talks to.
///
/// **This is the client half of the Embedded App SDK.** The frame posts
/// `[opcode, payload]` to its parent; the host page forwards it here; this
/// answers. The protocol is `ActivityRPC` — read off the shipping SDK, because
/// `postMessage` traffic is in no capture and never could be.
///
/// **Every command is answered, including the ones that are refused.** The SDK
/// resolves a promise per nonce, so a command this client drops is an app that
/// waits for ever — which reads as a broken activity rather than as a missing
/// feature. Anything unimplemented gets `INVALID_COMMAND` back.
@MainActor
final class ActivityBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let messageHandler = "wingcordActivity"
    /// `RPCCloseCodes.CLOSE_NORMAL` — the app finishing, rather than refusing.
    static let normalCloseCode = 1000

    private unowned let model: AppModel
    private let activity: RunningActivity
    private weak var webView: WKWebView?
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Activity")

    /// The state parameter this run's authorize round trip is keyed on. One per
    /// activity, generated here rather than taken from the app: it exists so
    /// *this* client can tell its own request apart from anything else.
    private let authorizeState = UUID().uuidString.lowercased()

    init(model: AppModel, activity: RunningActivity) {
        self.model = model
        self.activity = activity
    }

    /// The origin the host page is loaded at, and it is **not negotiable**.
    ///
    /// The SDK drops any message whose origin it does not recognise, before it
    /// looks at the payload at all:
    ///
    /// ```js
    /// // Discord.mjs
    /// const ALLOWED_ORIGINS = new Set([
    ///     window.location.origin, 'https://discord.com', 'https://discordapp.com',
    ///     'https://ptb.discord.com', …, 'http://localhost:3333', 'null',
    /// ]);
    /// this.handleMessage = (event) => {
    ///     if (!ALLOWED_ORIGINS.has(event.origin)) return;
    /// ```
    ///
    /// **This failed silently and in only one direction.** Loaded at
    /// `discordsays.com`, the frame's own messages arrived here perfectly — the
    /// SDK posts to `document.referrer`, which matched — and every reply this
    /// bridge sent was discarded without a word. Watch Together sat on its
    /// splash screen for ever, having sent a handshake and been answered by
    /// what looked to it like silence.
    ///
    /// `https://discord.com` is on the list. So is the literal string `null`,
    /// which is what an opaque origin serialises to — a `nil` base URL would
    /// also work, and is rejected only because a document with no origin cannot
    /// be reasoned about later.
    static let hostOrigin = URL(string: "https://discord.com/")

    /// An activity's own storage, shared by every activity and by nothing else.
    ///
    /// **Non-persistent.** These are third-party pages inside somebody's
    /// messenger; a persistent store would keep an app's cookies across
    /// sessions with no way for the reader to see or clear them.
    static let dataStore = WKWebsiteDataStore.nonPersistent()

    func attach(_ webView: WKWebView) { self.webView = webView }

    func detach(_ webView: WKWebView) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.messageHandler)
        webView.stopLoading()
        // Navigating away is what actually stops the frame's audio and its
        // timers; `stopLoading` alone leaves a running page running.
        webView.loadHTMLString("", baseURL: nil)
        self.webView = nil
    }

    // MARK: The host page

    /// One iframe, and the two functions that carry messages across it.
    ///
    /// `targetOrigin` is `*` deliberately: the frame's origin is
    /// `{id}.discordsays.com` and naming it would mean rebuilding this string
    /// per app for no gain — the only page in this web view is the one we put
    /// there, and the handler below checks the source window before trusting
    /// anything.
    static func hostPage(framing url: URL) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;padding:0;height:100%;background:transparent;overflow:hidden}
          iframe{display:block;border:0;width:100%;height:100%}
        </style></head><body>
        <iframe id="activity" src="\(escape(url.absoluteString))"
          allow="autoplay; clipboard-write; encrypted-media; fullscreen; microphone; camera; display-capture"
          sandbox="allow-scripts allow-same-origin allow-popups allow-forms allow-modals allow-downloads"
        ></iframe>
        </body></html>
        """
    }

    /// Injected at document end, so the iframe exists by the time it runs.
    static let hostScript = """
        (function () {
          var frame = document.getElementById('activity');
          if (!frame) return;
          window.addEventListener('message', function (event) {
            // Only the frame we put there. Anything else posting into this
            // window is not the activity and must not be forwarded as if it
            // were.
            if (event.source !== frame.contentWindow) return;
            try {
              window.webkit.messageHandlers.\(messageHandler)
                .postMessage(JSON.stringify(event.data));
            } catch (e) {}
          });
          window.__wingcordDeliver = function (json) {
            try { frame.contentWindow.postMessage(JSON.parse(json), '*'); } catch (e) {}
          };
        })();
        """

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    // MARK: Receiving

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let text = message.body as? String else { return }
        // **The raw frame, before any hypothesis about it.** An activity that
        // stalls after READY is waiting on a command this bridge answered
        // wrongly or not at all, and the only way to know which is to print
        // what it actually asked for. `INVARIANTS.md` — the video path was
        // found the same way.
        Self.trace("in  \(text.prefix(400))")
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let frame = ActivityFrameMessage(json: json)
        else {
            Self.trace("in  UNPARSED")
            return
        }
        handle(frame)
    }

    nonisolated static func trace(_ message: @autoclosure () -> String) {
        Log.debug(.games, .raw("activity: " + message()))
    }

    private func handle(_ frame: ActivityFrameMessage) {
        switch frame.opcode {
        case .handshake:
            // The SDK waits on READY before it sends anything else, so this is
            // the one reply that is not optional.
            model.markActivityReady()
            dispatch(event: "READY", data: [
                "v": 1,
                "config": [
                    "cdn_host": "cdn.discordapp.com",
                    "api_endpoint": "//discord.com/api",
                    "environment": "production",
                ],
            ].merging(
                // Omitted entirely when there is no signed-in user: `user` is
                // `.optional()` in the READY schema, and zod's `.optional()`
                // accepts `undefined` but rejects `null`.
                currentUserPayload.map { ["user": $0] } ?? [:],
                uniquingKeysWith: { _, new in new }
            ))
        case .frame:
            guard let command = frame.command else { return }
            perform(command, frame: frame)
        case .close:
            // **Say why.** An activity that closes itself has decided it cannot
            // run, and tearing the stage down silently leaves the reader with a
            // surface that appeared and vanished — indistinguishable from a
            // crash. The code is the SDK's `RPCCloseCodes`; `1000` is the app
            // deciding it is finished, and anything else is a refusal.
            let (code, message) = frame.closeReason
            Self.trace("close code=\(code) message=\(message ?? "-")")
            model.clearPublishedActivity()
            model.activityRuntime?.stop()
            model.activityRuntime = nil
            if code != Self.normalCloseCode {
                model.reportActionFailure(
                    message.map { "\(activity.name): \($0)" }
                        ?? "\(activity.name) closed itself (code \(code))."
                )
            }
            model.runningActivity = nil
        case .hello:
            break
        }
    }

    // MARK: Commands

    private func perform(_ command: String, frame: ActivityFrameMessage) {
        switch command {
        case "AUTHORIZE":
            authorize(frame)
        case "AUTHENTICATE":
            authenticate(frame)
        case "SUBSCRIBE", "UNSUBSCRIBE":
            // Acknowledged, and nothing is delivered. **The events this client
            // could raise are the ones it cannot verify** — the participant
            // list and the instance's own updates come from
            // `EMBEDDED_ACTIVITY_UPDATE_V2`, a dispatch with no published
            // payload and none in any capture here. An app that subscribes gets
            // a clean acknowledgement and no events, which is a quiet activity;
            // an app that got invented events would be a wrong one.
            // `SubscribeResponse` is `{ evt: string }` — the event's name goes
            // in the DATA, not in the frame's own `evt`, which must be null.
            reply(to: frame, data: ["evt": frame.event ?? ""])
        case "ENCOURAGE_HW_ACCELERATION":
            reply(to: frame, data: ["enabled": true])

        // The handful an app asks for while it is starting up. **Each shape is
        // read off the SDK's own response schemas** — an answer of the wrong
        // shape is not an error here, it is a dropped promise, and an app that
        // waits on one closes itself a few seconds later.
        case "SET_CONFIG":
            // `{ use_interactive_pip: boolean }`. False: there is no picture in
            // picture for an activity here, and claiming one would have the app
            // lay itself out for a control that does not exist.
            reply(to: frame, data: ["use_interactive_pip": false])
        case "USER_SETTINGS_GET_LOCALE":
            reply(to: frame, data: ["locale": model.sessionController.metadata.locale])
        case "GET_PLATFORM_BEHAVIORS":
            // Every key here is optional by the schema's own note, and the one
            // it defines is about the iOS keyboard.
            reply(to: frame, data: ["iosKeyboardResizesView": false])
        case "SET_ORIENTATION_LOCK_STATE", "SET_CERTIFIED_DEVICES", "SEND_ANALYTICS_EVENT":
            // `EmptyResponse`. Orientation is meaningless on a desktop window,
            // and the other two are the app telling the client something rather
            // than asking it anything.
            reply(to: frame, data: [:])
        case "GET_SKUS", "GET_ENTITLEMENTS":
            reply(to: frame, data: [:])
        case "GET_SKUS_EMBEDDED":
            // **Empty is the honest answer, not a refusal.** This client makes
            // no purchases and reads no store, so an app asking what is for sale
            // is told nothing is — which is true here — rather than being left
            // to time out.
            reply(to: frame, data: ["skus": []])
        case "GET_ENTITLEMENTS_EMBEDDED":
            reply(to: frame, data: ["entitlements": []])
        case "CAPTURE_LOG":
            Self.log.debug("activity: \(String(describing: frame.arguments["message"]))")
            reply(to: frame, data: [:])
        case "SET_ACTIVITY":
            // **Published, not dropped.** This is how an embedded app says what
            // it is doing — Watch Together sends
            // `{type: 3, details: "Adding videos", party: {…}}` a second or two
            // in — and it is the same object that draws "Watching Watch
            // Together / Adding videos / 0:05" in a profile popout.
            //
            // The name is filled in from the app when it sends none: `name` is
            // required both by the gateway and by the reply's own schema, and
            // an app that omits it means its own.
            var echo = frame.arguments["activity"] as? [String: Any] ?? [:]
            if echo["name"] == nil { echo["name"] = activity.name }
            if echo["type"] == nil { echo["type"] = 0 }
            model.publishActivity(echo, application: activity.applicationID)
            // **The reply echoes the activity back rather than answering `{}`.**
            // `SetActivityResponse` IS the `Activity` schema, whose `name` and
            // `type` are required; an empty object fails to parse, and a failed
            // parse here storms rather than errors. See `reply(to:data:)`.
            reply(to: frame, data: echo)
        case "GET_CHANNEL":
            getChannel(frame)
        case "GET_CHANNEL_PERMISSIONS":
            // `{ permissions: bigint | string }`. Sent as a **string**, because
            // the bitfield exceeds what JavaScript's `Number` can hold — which
            // is why Discord spells every one of these as a string on the wire.
            //
            // Only for the channel the activity was launched into; see
            // `getChannel` for why that is not a limitation worth relaxing.
            let channelID = activity.instance.location.channelID
            let requested = (frame.arguments["channel_id"] as? String).flatMap(ChannelID.init)
            guard requested == nil || requested == channelID else {
                refuse(frame, code: .invalidPermissions, message: "That channel is not available.")
                return
            }
            reply(to: frame, data: [
                "permissions": String(model.permissionGate.permissions(in: channelID).rawValue),
            ])
        case "GET_INSTANCE_CONNECTED_PARTICIPANTS",
             "GET_ACTIVITY_INSTANCE_CONNECTED_PARTICIPANTS":
            // The honest answer is "only you": this client joins no voice
            // channel on the activity's behalf and has no dispatch that names
            // the others. An empty list would be a lie about the reader
            // themselves.
            reply(to: frame, data: ["participants": [currentUserPayload].compactMap { $0 }])
        case "OPEN_EXTERNAL_LINK":
            openExternalLink(frame)
        default:
            Self.trace("REFUSED \(command)")
            refuse(frame, code: .invalidCommand, message: "\(command) is not supported here.")
        }
    }

    private func authorize(_ frame: ActivityFrameMessage) {
        // **`scope`, singular.** It is the OAuth2 parameter's own name and it is
        // what the SDK sends:
        //
        //     {"cmd":"AUTHORIZE","args":{"response_type":"code","state":"…",
        //      "prompt":"none","client_id":"…","scope":["identify", …]}}
        //
        // Read as `scopes` it is simply absent, and the grant is requested for
        // *nothing* — which Discord refuses, and which the app reports as
        // "User declined authorization" before closing itself. The plural is
        // accepted as a fallback rather than assumed away.
        let scopes = (frame.arguments["scope"] as? [String])
            ?? (frame.arguments["scopes"] as? [String])
            ?? []
        guard !scopes.isEmpty else {
            refuse(frame, code: .invalidPermissions, message: "No scopes requested.")
            return
        }
        // **The app's own state, not one this client invents.** The app checks
        // it against what comes back through its backend, so a substituted one
        // fails on its side for reasons nothing here would ever see.
        let state = frame.arguments["state"] as? String ?? authorizeState
        // **`prompt: "none"` is NOT honoured, and that is from the capture.**
        //
        // Its OAuth meaning is "do not prompt; fail if there is no grant", and
        // reading it that way is wrong here: the captured first launch of Watch
        // Together shows Discord presenting its consent modal, and this client's
        // own trace shows Watch Together sending `prompt: "none"`. Both are only
        // true if the reference client shows the sheet regardless. Honouring it
        // made Magic Garden — an app this account had never authorized — retry
        // four times and give up with "Authentication Failed 4006".
        //
        // Pressing Launch is the reader asking for the app; the sheet is where
        // they see what it wants. An app cannot opt out of that.
        let channelID = activity.instance.location.channelID
        Task {
            do {
                let authorization = try await model.sessionController.rest.activityAuthorization(
                    application: activity.applicationID,
                    scopes: scopes,
                    state: state
                )
                // **Already granted means no sheet.** The route says so, and a
                // consent sheet in front of somebody who consented last week is
                // a dialog they have to dismiss to use the thing they opened.
                if authorization.isAlreadyAuthorized {
                    await finishAuthorize(
                        frame, scopes: scopes, state: state, channelID: channelID
                    )
                    return
                }
                let code = await withCheckedContinuation { continuation in
                    model.activityConsent = ActivityConsentRequest(
                        authorization: authorization,
                        channelID: channelID,
                        guildID: activity.instance.location.guildID,
                        channelKind: model.channelIndex[channelID]?.kind.rawValue ?? 1,
                        state: state,
                        reply: { continuation.resume(returning: $0) }
                    )
                }
                model.activityConsent = nil
                guard let code else {
                    refuse(frame, code: .invalidPermissions, message: "Not authorized.")
                    return
                }
                reply(to: frame, data: ["code": code])
            } catch {
                // The reason, not just the refusal — the app is told the same
                // thing either way, and without this the log says only that it
                // failed.
                Self.trace("authorize failed: \(error)")
                refuse(frame, code: .invalidPermissions, message: "Not authorized.")
            }
        }
    }

    /// The grant already existed, so the code is taken without a sheet.
    private func finishAuthorize(
        _ frame: ActivityFrameMessage,
        scopes: [String],
        state: String,
        channelID: ChannelID
    ) async {
        do {
            let code = try await model.sessionController.rest.authorizeActivity(
                application: activity.applicationID,
                scopes: scopes,
                state: state,
                channelID: channelID,
                guildID: activity.instance.location.guildID,
                channelKind: model.channelIndex[channelID]?.kind.rawValue ?? 1
            )
            reply(to: frame, data: ["code": code])
        } catch {
            Self.trace("authorize (existing grant) failed: \(error)")
            refuse(frame, code: .invalidPermissions, message: "Not authorized.")
        }
    }

    /// The app hands back a token its own backend exchanged the code for, and
    /// this says who it belongs to.
    ///
    /// **The token is the app's, not the account's.** It is validated by
    /// calling `GET /oauth2/@me` *as that token* — the same request the capture
    /// makes immediately after the authorize round trip.
    private func authenticate(_ frame: ActivityFrameMessage) {
        guard let token = frame.arguments["access_token"] as? String, !token.isEmpty else {
            refuse(frame, code: .invalidPermissions, message: "No access token.")
            return
        }
        Task {
            do {
                let identity = try await model.sessionController.rest.oauthIdentity(bearer: token)
                // Shaped by `AuthenticateResponseSchema` in the SDK's generated
                // schemas, which is stricter than the rest of the protocol:
                // `user.public_flags`, `expires` and `application.description`
                // are all **required**, and a missing one fails the parse — see
                // `reply(to:data:)` for why that storms rather than fails.
                reply(to: frame, data: [
                    "access_token": token,
                    "user": Self.payload(for: identity.user),
                    "scopes": identity.scopes,
                    // Required and non-nullable. A grant with no stated expiry
                    // is reported as the far future rather than omitted.
                    "expires": Self.iso8601(identity.expires ?? .distantFuture),
                    "application": [
                        "id": activity.applicationID.description,
                        "name": identity.application?.name ?? activity.name,
                        "description": identity.application?.about ?? "",
                    ],
                ])
            } catch {
                refuse(frame, code: .invalidPermissions, message: "That token was refused.")
            }
        }
    }

    private func getChannel(_ frame: ActivityFrameMessage) {
        let requested = (frame.arguments["channel_id"] as? String).flatMap(ChannelID.init)
        let channelID = requested ?? activity.instance.location.channelID
        // Only the channel the activity was launched into. An app asking about
        // a different one is asking this client to read the account's channel
        // list on its behalf, which is not a thing it was granted.
        guard channelID == activity.instance.location.channelID,
              let channel = model.channelIndex[channelID]
        else {
            refuse(frame, code: .invalidPermissions, message: "That channel is not available.")
            return
        }
        reply(to: frame, data: [
            "id": channel.id.description,
            "type": channel.kind.rawValue,
            "guild_id": activity.instance.location.guildID?.description as Any,
            "name": model.displayName(of: channel),
            // Deliberately empty. The transcript is the reader's, and an
            // activity has no business reading it.
            "messages": [],
            "voice_states": [],
        ])
    }

    private func openExternalLink(_ frame: ActivityFrameMessage) {
        guard let text = frame.arguments["url"] as? String,
              let url = URL(string: text),
              url.scheme == "https"
        else {
            refuse(frame, code: .invalidPermissions, message: "That link cannot be opened.")
            return
        }
        // Through the reader's browser, and only `https`. An activity handing
        // this client an arbitrary scheme is an activity asking it to open
        // whatever that scheme is registered to.
        NSWorkspace.shared.open(url)
        reply(to: frame, data: ["opened": true])
    }

    // MARK: Replying

    /// A reply to a command.
    ///
    /// **`evt` must be present and explicitly `null`, and `nonce` must be a
    /// string.** Not "may be omitted" — the SDK validates every inbound frame
    /// against `ReceiveFramePayload` before it looks at anything:
    ///
    /// ```js
    /// const ReceiveFramePayload = objectType({
    ///     cmd: stringType(), data: unknownType(),
    ///     evt: nullType(),          // ← required, and must BE null
    ///     nonce: stringType(),      // ← required, and NOT nullable
    /// }).passthrough();
    /// ```
    ///
    /// **Getting this wrong does not fail; it storms.** A frame that will not
    /// parse is logged with `console.error` and the pending promise is dropped
    /// — and the SDK *overrides `console.error` to send `CAPTURE_LOG` back to
    /// the client*. So one malformed reply produces two log commands, whose two
    /// malformed replies produce four, and the frame's main thread saturates.
    /// Watch Together's spinner freezing mid-rotation was this, not a hang.
    /// The SDK's own source warns about the loop in as many words.
    private func reply(to frame: ActivityFrameMessage, data: [String: Any]) {
        guard let body = ActivityReply.response(
            command: frame.command, nonce: frame.nonce, data: data
        ) else {
            Self.trace("out SKIPPED \(frame.command ?? "?") — no nonce")
            return
        }
        post(body)
    }

    private func refuse(
        _ frame: ActivityFrameMessage,
        code: ActivityRPCError,
        message: String
    ) {
        guard let body = ActivityReply.error(
            command: frame.command, nonce: frame.nonce, code: code, message: message
        ) else { return }
        post(body)
    }

    private func dispatch(event: String, data: [String: Any]) {
        post(ActivityReply.dispatch(event: event, data: data))
    }

    private func post(_ body: [String: Any]) {
        guard let webView,
              let json = try? JSONSerialization.data(
                  withJSONObject: [ActivityOpcode.frame.rawValue, body]
              ),
              let text = String(data: json, encoding: .utf8)
        else {
            Self.trace("out DROPPED \(body["cmd"] ?? "?") — no web view or unencodable")
            return
        }
        Self.trace("out \(text.prefix(400))")
        // Passed as a JSON *string* argument rather than interpolated into the
        // script: a payload containing a quote would otherwise end the literal
        // and the rest of it would be evaluated as code.
        webView.callAsyncJavaScript(
            "window.__wingcordDeliver(payload)",
            arguments: ["payload": text],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    // MARK: Payloads

    private var currentUserPayload: [String: Any]? {
        model.currentUserID.flatMap { model.users[$0] }.map(Self.payload(for:))
    }

    /// **A nil field is OMITTED, never sent as null.** `avatar` and
    /// `global_name` are `.optional()` in the SDK's schema, and zod's
    /// `.optional()` accepts `undefined` — it does **not** accept `null`. An
    /// account with no avatar would otherwise fail the parse and storm.
    /// `public_flags` is required outright.
    private static func payload(for user: User) -> [String: Any] {
        ActivityReply.user(
            id: user.id.description,
            username: user.username,
            discriminator: user.discriminator,
            publicFlags: user.flags.rawValue,
            avatar: user.avatarHash,
            globalName: user.displayName
        )
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: Navigation

    /// **The frame may not navigate the host page.** Anything that is not the
    /// iframe's own load is refused: a top-level navigation would replace the
    /// host page and take the bridge with it.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        MainActor.assumeIsolated {
            Self.trace(
                "nav \(navigationAction.request.url?.absoluteString.prefix(160) ?? "?") "
                    + "main=\(navigationAction.targetFrame?.isMainFrame ?? false)"
            )
            let isTopLevel = navigationAction.targetFrame?.isMainFrame ?? false
            let url = navigationAction.request.url
            if isTopLevel, url?.scheme != "about", navigationAction.navigationType == .linkActivated {
                if let url, url.scheme == "https" { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    /// An activity opening a window opens it in the reader's browser instead.
    nonisolated func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        MainActor.assumeIsolated {
            if let url = navigationAction.request.url, url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}
