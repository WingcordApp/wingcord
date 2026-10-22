import SwiftUI
import WingcordCore

/// The line under Now Playing's switch: what plays, and whether it is shared —
/// or why not. Read through the presence, which is `@Observable`, so it
/// follows the song.
struct NowPlayingStateLine: View {
    var presence: NowPlayingPresence
    /// The account's "Share my activity".
    var sharesActivity: Bool

    var body: some View {
        SettingsFootnote(text, symbolName: symbolName)
    }

    private var symbolName: String {
        if presence.activity != nil { return presence.player?.kind == .watching ? "play.tv" : "waveform" }
        return presence.snapshot == nil ? "music.note" : "pause.circle"
    }

    private var text: String {
        guard sharesActivity else {
            return "Share my activity is off, so nothing that plays is shared."
        }
        guard let snapshot = presence.snapshot else {
            return "Nothing is playing. Start something and it appears here."
        }
        if let activity = presence.activity {
            let verb = activity.type == MediaPlayer.Kind.watching.activityType ? "Watching" : "Listening to"
            let shared = activity.details.map { "\u{201C}\($0)\u{201D}" } ?? "it"
            return "Sharing \(shared) as \(verb) \(activity.name)."
        }
        let what = "\u{201C}\(snapshot.title)\u{201D}"
        let player = presence.player?.name ?? "it"
        switch presence.hold {
        case .looking:
            return "Finding out where \(what) is playing…"
        case .paused:
            return "\(what) is paused — it\u{2019}s shared again when it plays."
        case .playerOff:
            return "\(what) is playing in \(player), which is switched off below."
        case .excluded:
            return "\(what) has a word you never share."
        case .shownBySpotify:
            return "\(what) is already shown by your Spotify connection."
        case .noPage:
            return "\(what) is playing in a browser that couldn\u{2019}t say which tab."
        case .browserDenied:
            return "\(what) is playing in a browser Wingcord isn\u{2019}t allowed to ask."
        case nil:
            return "\(what) is playing."
        }
    }
}
