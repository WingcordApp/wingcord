import Foundation
import Testing
import WingcordCore
@testable import WingcordNet
@testable import Wingcord

/// Which route each edit goes to — docs/CLIPS-PRESENCE.md, Phase 9.
///
/// **A per-server save is two requests, not one.** Discord's own (build
/// 643186) sends what is worn as a member — nickname, avatar, decoration,
/// nameplate, name style — to `PATCH /guilds/{id}/members/@me`, and the profile
/// — bio, pronouns, colours, banner, effect, frame — to
/// `PATCH /guilds/{id}/profile/@me`. Wingcord used to send only the nickname to
/// the first, so a per-server avatar, decoration, plate or style was dropped.
@MainActor
@Suite("Profile save routing")
struct ProfileSaveRoutingTests {

    private let guildID = GuildID(rawValue: 77)

    private func profile(worn: [WornCollectible]? = nil) -> ProfilePresentation {
        var presentation = ProfilePresentation(
            userID: UserID(rawValue: 1), displayName: "alex", handle: "alex", monogram: "A",
            status: .online, isBot: false, badges: [], roles: [], accountCreated: .distantPast,
            isSelf: true, connections: [], premiumTier: .nitro, mutualServers: [], mutualFriends: [],
            isProfilePrivate: false, note: "", isLoading: false
        )
        presentation.wornCollectibles = worn
        return presentation
    }

    @Test("A server save splits across the member and profile routes")
    func serverSaveSplits() async throws {
        let (rest, token) = await SaveRecorder.client()
        let editor = ProfileEditor(profile: profile(), widgets: [], scope: .guild(guildID), accountName: "alex")
        editor.nickname = "lex"
        editor.avatarDecorationSKU = "deco"
        editor.wear(OwnedCollectible(skuID: "plate", name: "Plate", kind: .nameplate, asset: "nameplates/x/"), kind: .nameplate)
        editor.displayNameStyle = DisplayNameStyle(font: .tempo, effect: .solid, colors: [0xFF_00_00])
        editor.bio = "hello"
        editor.themeColors = [0x11_22_33, 0x44_55_66]

        let saved = await editor.save(using: rest)
        #expect(saved, "\(editor.failure ?? "")")

        let requests = SaveRecorder.requests(for: token)
        let member = try #require(requests.first { $0.path.hasSuffix("/guilds/77/members/@me") })
        let memberBody = try #require(member.json)
        #expect(memberBody["nick"] as? String == "lex")
        #expect(memberBody["avatar_decoration_sku_id"] as? String == "deco")
        #expect((memberBody["collectibles"] as? [String: Any])?["nameplate"] != nil)
        #expect(memberBody["display_name_font_id"] != nil)
        #expect(memberBody["bio"] == nil)

        let page = try #require(requests.first { $0.path.contains("/guilds/77/profile/") })
        let pageBody = try #require(page.json)
        #expect(pageBody["bio"] as? String == "hello")
        #expect(pageBody["theme_colors"] as? [Int] == [0x11_22_33, 0x44_55_66])
        #expect(pageBody["nick"] == nil)
        #expect(requests.count == 2)
    }

    @Test("Changing the effect keeps every other worn collectible")
    func effectKeepsTheRest() async throws {
        let (rest, token) = await SaveRecorder.client()
        let worn = [
            WornCollectible(skuID: "frame", kind: .profileFrame),
            WornCollectible(skuID: "old", kind: .profileEffect),
        ]
        let editor = ProfileEditor(profile: profile(worn: worn), widgets: [], scope: .account)
        #expect(editor.profileFrameSKU == "frame")
        #expect(editor.profileEffectSKU == "old")
        editor.profileEffectSKU = "new"

        #expect(await editor.save(using: rest))
        let requests = SaveRecorder.requests(for: token)
        let page = try #require(requests.first { $0.path.contains("/users/") && $0.path.hasSuffix("/profile") })
        #expect(page.json?["collectibles_sku_ids"] as? [String] == ["frame", "new"])
        #expect(requests.count == 1)
    }

    @Test("An uploaded avatar carries its alt text; a recent one does not")
    func avatarAltText() async throws {
        let (rest, token) = await SaveRecorder.client()
        let editor = ProfileEditor(profile: profile(), widgets: [], scope: .account)
        editor.avatar = .uploaded(.png(Data([1, 2, 3])))
        editor.avatarDescription = "  a cat in a box  "
        #expect(await editor.save(using: rest))
        let account = try #require(SaveRecorder.requests(for: token).first { $0.path.hasSuffix("/users/@me") })
        #expect(account.json?["avatar_description"] as? String == "a cat in a box")
        #expect((account.json?["avatar"] as? String)?.hasPrefix("data:image/png;base64,") == true)

        let (rest2, token2) = await SaveRecorder.client()
        let second = ProfileEditor(profile: profile(), widgets: [], scope: .guild(guildID), accountName: "alex")
        second.avatar = .recent(RecentAvatar(id: "9", storageHash: "abc"))
        second.avatarDescription = "ignored"
        #expect(await second.save(using: rest2))
        let member = try #require(SaveRecorder.requests(for: token2).first { $0.path.hasSuffix("/members/@me") })
        #expect(member.json?["avatar_id"] as? String == "9")
        #expect(member.json?["avatar_description"] == nil)
    }

    @Test("An untouched editor saves nothing")
    func untouchedSendsNothing() async {
        let (rest, token) = await SaveRecorder.client()
        let editor = ProfileEditor(profile: profile(), widgets: [], scope: .guild(guildID), accountName: "alex")
        #expect(!editor.isDirty)
        #expect(await editor.save(using: rest))
        #expect(SaveRecorder.requests(for: token).isEmpty)
    }

    @Test("Leaving with changes unsaved nudges instead")
    func nudge() {
        let editor = ProfileEditor(profile: profile(), widgets: [], scope: .account)
        editor.bio = "changed"
        #expect(editor.isDirty)
        editor.nudge()
        #expect(editor.nudges == 1)
    }

    @Test("Theme stops are written as a pair and swap")
    func themeStops() {
        let editor = ProfileEditor(profile: profile(), widgets: [], scope: .account)
        editor.setThemeStop(1, to: 0xAB_CD_EF)
        #expect(editor.themeColors?.count == 2)
        #expect(editor.themeColors?[1] == 0xAB_CD_EF)
        let first = editor.themeStop(0)
        editor.swapThemeStops()
        #expect(editor.themeColors == [0xAB_CD_EF, first])
    }
}

/// Records what a save sends, and answers the member route with a member.
private nonisolated final class SaveRecorder: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        var method: String
        var path: String
        var body: Data?
        var json: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [String: [Captured]] = [:]

    static func client() async -> (DiscordREST, String) {
        let token = "save-\(UUID().uuidString)"
        let rest = DiscordREST(protocolClasses: [SaveRecorder.self])
        await rest.setToken(token)
        return (rest, token)
    }

    static func requests(for token: String) -> [Captured] {
        lock.withLock { captured[token] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let path = request.url?.path(percentEncoded: true) ?? ""
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        Self.lock.withLock {
            Self.captured[token, default: []].append(Captured(method: request.httpMethod ?? "GET", path: path, body: body))
        }
        let reply = path.hasSuffix("/members/@me")
            ? #"{"user":{"id":"1","username":"alex","discriminator":"0"},"nick":"lex","roles":[]}"#
            : path.hasSuffix("/users/@me")
                ? #"{"id":"1","username":"alex","discriminator":"0"}"#
                : "{}"
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://discord.com")!,
            statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
