import Foundation
import Testing
@testable import WingcordNet

/// The web build read off discord.com/app, and the floor it can only raise.
struct DiscordWebBuildTests {

    @Test func readsTheBuildNumberOutOfGlobalEnv() {
        // The shape of the page's inline script, 2026-11-17.
        let html = #"<script nonce="x">window.GLOBAL_ENV = {"API_ENDPOINT":"//discord.com/api","BUILD_NUMBER":"675174","PROJECT_ENV":"production"}</script>"#
        #expect(DiscordWebBuild.parse(html) == 675_174)
    }

    @Test func acceptsAnUnquotedNumber() {
        #expect(DiscordWebBuild.parse(#"{"BUILD_NUMBER": 681002, "X": 1}"#) == 681_002)
    }

    @Test func aPageWithoutTheNumberReadsAsNothing() {
        #expect(DiscordWebBuild.parse("<html><body>Discord</body></html>") == nil)
        // Five digits is not a build of this decade.
        #expect(DiscordWebBuild.parse(#""BUILD_NUMBER":"12345""#) == nil)
    }

    @Test func theFloorOnlyMovesForward() {
        let floor = ClientMetadata.Baseline.current
        #expect(floor.with(webBuildNumber: nil).webBuildNumber == floor.webBuildNumber)
        #expect(floor.with(webBuildNumber: floor.webBuildNumber - 10).webBuildNumber == floor.webBuildNumber)
        #expect(floor.with(webBuildNumber: floor.webBuildNumber + 10).webBuildNumber == floor.webBuildNumber + 10)
    }

    @Test func theHeaderCarriesTheRaisedNumber() throws {
        let raised = ClientMetadata.Baseline.current.with(webBuildNumber: 700_001)
        let metadata = ClientMetadata(baseline: raised)
        let decoded = try #require(Data(base64Encoded: metadata.superProperties))
        let object = try #require(try JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        #expect(object["client_build_number"] as? Int == 700_001)
    }
}
