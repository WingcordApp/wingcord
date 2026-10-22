import Foundation
import Testing
@testable import WingcordCore

/// Finding the tab a browser's media plays from.
struct BrowserTabsTests {
    private func page(_ address: String, _ title: String) -> BrowserTab {
        BrowserTab(url: URL(string: address)!, title: title)
    }

    @Test("Safari is asked for `name`, Chromium for `title`; Firefox is not asked")
    func scripts() throws {
        let safari = try #require(BrowserTabs.script(for: "com.apple.Safari"))
        #expect(safari.contains(#"tell application id "com.apple.Safari""#))
        #expect(safari.contains("name of every tab of every window"))
        let chrome = try #require(BrowserTabs.script(for: "com.google.Chrome"))
        #expect(chrome.contains("title of every tab of every window"))
        #expect(BrowserTabs.script(for: "org.mozilla.firefox") == nil)
        #expect(BrowserTabs.script(for: "com.apple.Music") == nil)
    }

    @Test("Output lines become pages; anything else is skipped")
    func parses() {
        let output = "https://www.youtube.com/watch?v=dQw4w9WgXcQ\u{1F}Video - YouTube\n"
            + "favorites://\u{1F}Favourites\n"
            + "garbage line\n"
            + "https://example.com/a\u{1F}Title \u{1F} with a separator\n\n"
        let pages = BrowserTabs.tabs(from: output)
        #expect(pages.count == 2)
        #expect(pages[0] == page("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "Video - YouTube"))
        #expect(pages[1].title == "Title \u{1F} with a separator")
    }

    @Test("The playing tab carries the media's title — a known site first")
    func matchesTitle() {
        let pages = [
            page("https://news.example.com/story", "Nintendo Games Are Now Running Natively on Mac — a review"),
            page("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "(3) Nintendo Games Are Now Running Natively on Mac - YouTube"),
            page("https://www.youtube.com/watch?v=aaaaaaaaaaa", "Something Else - YouTube"),
        ]
        #expect(BrowserTabs.playingTab(among: pages, title: "Nintendo Games Are Now Running Natively on Mac") == pages[1])
    }

    @Test("A music site's only tab plays whatever it plays; a video tab is never guessed")
    func fallsBackOnlyToMusicSites() {
        let music = page("https://music.youtube.com/watch?v=dQw4w9WgXcQ", "YouTube Music")
        let video = page("https://www.youtube.com/watch?v=aaaaaaaaaaa", "Something Else - YouTube")
        #expect(BrowserTabs.playingTab(among: [music, video], title: "Never Gonna Give You Up") == music)
        #expect(BrowserTabs.playingTab(among: [video], title: "Never Gonna Give You Up") == nil)
        let second = page("https://soundcloud.com/artist/track", "Stream track")
        #expect(BrowserTabs.playingTab(among: [music, second], title: "Never Gonna Give You Up") == nil)
    }

    @Test("A declined Automation request is -1743")
    func permissionDenied() {
        #expect(BrowserTabs.isPermissionDenied("execution error: Not authorised to send Apple events to Safari. (-1743)"))
        #expect(!BrowserTabs.isPermissionDenied("execution error: Safari got an error: Can’t get window 1. (-1728)"))
    }
}
