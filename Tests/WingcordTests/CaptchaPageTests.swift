import Foundation
import Testing
@testable import Wingcord

/// The hCaptcha page, held to Discord's own client (`283cac4b…`, `645320`):
/// `rqdata` goes in through `setData` after the render, never among the render's
/// options — passed at render, the token wasn't bound to the challenge and
/// Discord refused every one this app made (2026-11-06, a QR login's check).
@MainActor
@Suite("Captcha page")
struct CaptchaPageTests {

    private let rqdata = "MUO5r+7AQ7gDZpe1PUio5lv1Qwet"

    @Test("rqdata is bound with setData, after the render, and not passed to it")
    func rqdataThroughSetData() throws {
        let html = HCaptchaPage.html(sitekey: "a9b5fb07", rqdata: rqdata, isInvisible: false, messageName: "m")
        #expect(html.contains("hcaptcha.setData(widget, { rqdata: rqdata })"))
        #expect(html.contains("var rqdata = \"\(rqdata)\""))
        let render = try #require(html.range(of: "hcaptcha.render("))
        let renderOptions = html[render.upperBound...].prefix { $0 != ";" }
        #expect(!renderOptions.contains("rqdata"))
    }

    @Test("The checkbox by default; invisible and executed when Discord asks")
    func size() {
        let checkbox = HCaptchaPage.html(sitekey: "s", rqdata: nil, isInvisible: false, messageName: "m")
        #expect(checkbox.contains("var invisible = false"))
        let invisible = HCaptchaPage.html(sitekey: "s", rqdata: nil, isInvisible: true, messageName: "m")
        #expect(invisible.contains("var invisible = true"))
        #expect(invisible.contains("hcaptcha.execute(widget)"))
    }

    @Test("The script is loaded as Discord's wrapper loads it")
    func script() {
        let html = HCaptchaPage.html(sitekey: "s", rqdata: nil, isInvisible: false, messageName: "m")
        #expect(html.contains("render=explicit"))
        #expect(html.contains("recaptchacompat=off"))
        #expect(html.contains("var rqdata = null"))
    }
}
