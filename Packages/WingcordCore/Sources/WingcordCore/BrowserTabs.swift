import Foundation

// MARK: - Which tab is playing
//
// A browser's media session carries the title and the artist but not the page
// (docs/CLIPS-PRESENCE.md §2.2), and the page is what says which site it is,
// which video, and where its buttons go. So the browser is asked, over
// AppleScript, for every tab's address and title, and the playing one is the
// tab whose title carries the media's — YouTube titles a tab "<video> -
// YouTube". Firefox and Zen have no tabs to ask for.

public enum BrowserTabs {

    /// The AppleScript that lists every tab of a running browser: one per line,
    /// its address and its title split by U+001F. Nil for a browser that cannot
    /// be asked.
    ///
    /// **Two Apple Events in all, not two per tab**: every address at once, then
    /// every title, paired up in the script. Asked tab by tab, a browser with
    /// a few windows took six seconds to answer (2026-10-20). A window with no
    /// tabs (Safari's Settings) fails the whole question, so then it is asked
    /// window by window; a blank tab's address is `missing value`, skipped.
    public static func script(for bundleIdentifier: String) -> String? {
        guard MediaPlayers.scriptableBrowsers.contains(bundleIdentifier) else { return nil }
        // Safari's dictionary names a tab's title `name`; Chromium's, `title`.
        let title = safariScripting.contains(bundleIdentifier) ? "name" : "title"
        return """
        set theURLs to {}
        set theTitles to {}
        tell application id "\(bundleIdentifier)"
            try
                set theURLs to URL of every tab of every window
                set theTitles to \(title) of every tab of every window
            on error
                set theURLs to {}
                set theTitles to {}
                repeat with w in windows
                    try
                        set windowURLs to URL of every tab of w
                        set windowTitles to \(title) of every tab of w
                        set end of theURLs to windowURLs
                        set end of theTitles to windowTitles
                    end try
                end repeat
            end try
        end tell
        set out to ""
        repeat with w from 1 to count of theURLs
            set windowURLs to item w of theURLs
            set windowTitles to item w of theTitles
            repeat with t from 1 to count of windowURLs
                try
                    set out to out & (item t of windowURLs) & (character id 31) & (item t of windowTitles) & linefeed
                end try
            end repeat
        end repeat
        return out
        """
    }

    /// Browsers whose scripting follows Safari's.
    static let safariScripting: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS"]

    /// The script's output as tabs; a line that is not an address and a title
    /// is skipped.
    public static func tabs(from output: String) -> [BrowserTab] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let url = URL(string: String(fields[0])), url.scheme?.hasPrefix("http") == true
            else { return nil }
            return BrowserTab(url: url, title: String(fields[1]))
        }
    }

    /// The tab playing `title`: the one whose title carries it — on a known
    /// site first, when several do. Failing that, the only tab on a site that
    /// plays music from one page (YouTube Music, SoundCloud…), whose tab need
    /// not name the song.
    ///
    /// **Never a guess among video tabs**: the page decides the thumbnail and
    /// the buttons, and the wrong tab would publish a video nobody is watching.
    public static func playingTab(among pages: [BrowserTab], title: String) -> BrowserTab? {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            let carrying = pages.filter { $0.title.localizedCaseInsensitiveContains(needle) }
            if let known = carrying.first(where: { MediaPlayers.site(for: $0.url) != nil }) { return known }
            if let first = carrying.first { return first }
        }
        let players = pages.filter { MediaPlayers.site(for: $0.url).map { $0.kind == .listening } ?? false }
        return players.count == 1 ? players[0] : nil
    }

    /// What `osascript` reports when the reader declined Automation for this
    /// browser — `errAEEventNotPermitted`, -1743.
    public static func isPermissionDenied(_ standardError: String) -> Bool {
        standardError.contains("-1743")
    }
}
