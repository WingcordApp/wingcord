import Foundation

// The human check Discord answers a write with instead of doing it.
//
// **Captured**, `forza onboarding1.har`, entries 4 and 9 — the same request
// twice, three headers apart. `POST /invites/forza` with `{"session_id": …}`
// comes back `400`:
//
// ```
// {"captcha_key":["You need to update your app to join this server."],
//  "captcha_sitekey":"a9b5fb07-92ff-493f-86fe-352a2803b3df",
//  "captcha_service":"hcaptcha",
//  "captcha_session_id":"4d637c3a-2dcf-435f-b304-b085a38306ed",
//  "captcha_rqdata":"MUO5r+7AQ7gDZpe1PUio5lv1Qwet…",
//  "captcha_rqtoken":"IkV2ak5zSUZ4ZUpWZ2xqOGVGa3l6…"}
// ```
//
// and the identical request, plus `X-Captcha-Key`, `X-Captcha-Rqtoken` and
// `X-Captcha-Session-Id`, comes back `200` with the guild.
//
// Three facts in that pair, none of them guessable:
//
//  1. **`captcha_key` is an array of PROSE, not a code.** The captured value is
//     the sentence "You need to update your app to join this server." — which is
//     what an app that surfaced it would tell somebody to do, and it is wrong.
//     Nothing is read from it; its presence is not even the signal. The
//     **sitekey** is, because it is the one field the challenge cannot run
//     without.
//  2. **`captcha_session_id` exists and is echoed.** It is absent from every
//     description of this envelope this project has seen written down, and a
//     retry that dropped it is a retry with a token bound to a session the
//     server is not holding.
//  3. **The 400 carries no `code` and no `message`.** So it does not survive
//     `apiFailure`, which reads exactly those two keys — the challenge has to be
//     recognised *before* the status is turned into an error, which is why this
//     lives inside `requestData` and not at a call site.

/// A challenge Discord raised, on its way to somebody who can answer it.
public struct CaptchaChallenge: Sendable, Hashable {
    /// `hcaptcha` on every observation. Kept because a solver can only present
    /// what it implements, and a service it does not know must fail as the
    /// original rejection rather than as an empty window.
    public var service: String?
    /// hCaptcha's site key — **the one field without which there is no
    /// challenge**, which is what makes its absence the test rather than
    /// `captcha_key`'s presence.
    public var sitekey: String
    /// Echoed back as `X-Captcha-Session-Id`.
    public var sessionID: String?
    /// The enterprise payload. hCaptcha issues a token without it and Discord
    /// rejects that token — which reads as a wrong answer rather than a missing
    /// parameter, and is the most expensive way this can fail.
    public var rqdata: String?
    /// Echoed back as `X-Captcha-Rqtoken`.
    public var rqtoken: String?

    /// Whether this build can put the challenge on screen at all.
    public var isSolvable: Bool {
        service == nil || service?.lowercased() == "hcaptcha"
    }
}

/// A solved challenge, on its way back to the request that was refused.
///
/// The three header names are the ones the captured retry sends; none is
/// invented.
public struct CaptchaSolution: Sendable, Hashable {
    /// hCaptcha's token. **Single use**, which is why the retry is scoped to the
    /// one request that was challenged rather than replayed across a flow.
    public var key: String
    public var rqtoken: String?
    public var sessionID: String?

    public init(key: String, rqtoken: String? = nil, sessionID: String? = nil) {
        self.key = key
        self.rqtoken = rqtoken
        self.sessionID = sessionID
    }

    func apply(to request: inout URLRequest) {
        request.setValue(key, forHTTPHeaderField: "X-Captcha-Key")
        if let rqtoken { request.setValue(rqtoken, forHTTPHeaderField: "X-Captcha-Rqtoken") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "X-Captcha-Session-Id") }
    }
}

/// Whoever can put a challenge in front of a person.
///
/// The REST actor awaits this from **inside** the request it is retrying, so a
/// conforming type has one job: show the challenge and answer with what comes
/// back. `nil` means nobody solved it — cancelled, dismissed, or no window
/// mounted to show one — and the request then fails with Discord's own
/// rejection rather than with something invented here.
public protocol CaptchaSolving: Sendable {
    func solve(_ challenge: CaptchaChallenge) async -> CaptchaSolution?
}

/// The envelope, as it arrives.
struct CaptchaChallengeDTO: Decodable, Sendable {
    var captcha_key: [String]?
    var captcha_sitekey: String?
    var captcha_service: String?
    var captcha_session_id: String?
    var captcha_rqdata: String?
    var captcha_rqtoken: String?

    /// Nil unless this really is a challenge.
    ///
    /// **Gated on the sitekey**, for the reason in the header note: `captcha_key`
    /// carries a sentence rather than a code, and an ordinary 400 that happened
    /// to be shaped like this would otherwise open a window at somebody.
    var domain: CaptchaChallenge? {
        guard let sitekey = captcha_sitekey, !sitekey.isEmpty else { return nil }
        return CaptchaChallenge(
            service: captcha_service,
            sitekey: sitekey,
            sessionID: captcha_session_id,
            rqdata: captcha_rqdata,
            rqtoken: captcha_rqtoken
        )
    }
}

extension DiscordREST {

    /// Installs the object that can answer a challenge.
    ///
    /// Optional by design: with none installed every challenged write fails with
    /// Discord's rejection, which is what a headless build and the test suite
    /// both want. Nothing here ever waits on a window that cannot appear.
    public func setCaptchaSolver(_ solver: (any CaptchaSolving)?) {
        captchaSolver = solver
    }

    /// The challenge in a 400 body, if it is one.
    ///
    /// A `nonisolated` pure function over bytes so the retry path in
    /// `requestData` costs one decode and no hop.
    nonisolated static func captchaChallenge(in data: Data) -> CaptchaChallenge? {
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(CaptchaChallengeDTO.self, from: data))?.domain
    }
}
