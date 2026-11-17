import Foundation
import WingcordCore

/// Everything an activity popout draws, resolved once from the entry, the
/// author's live presence and the store — Discord's popouts in `420018`
/// (`cT`, `c$`, `up`, `us`, `ux`, `uj`, `cS`; docs/ACTIVITY-CARDS.md
/// decisions 8 to 10).
struct ActivityPopoutPresentation: Equatable {
    struct Person: Equatable {
        var userID: UserID
        var name: String
        var style: DisplayNameStyle?
        var avatarURL: URL?
        var monogram: String
    }

    /// What the title, the subtitle or the picture opens.
    enum Destination: Equatable {
        case gameProfile(ApplicationID)
        case link(URL)
    }

    /// The mark in the hero's corner: a console, Spotify, Crunchyroll.
    struct Corner: Equatable {
        var service: String
        var label: String
        var destination: Destination?
    }

    /// The author's voice channel, for a live entry — Discord's voice bar.
    struct VoiceBar: Equatable {
        var channelID: ChannelID
        var guildIconURL: URL?
        var guildMonogram: String
        var channelName: String
        var faces: [ActivityMarkerFace]
        var extraCount: Int
        var isStreaming: Bool
        var isReaderHere: Bool
    }

    var entryID: String
    var authorID: UserID
    /// Up to three faces, and the two names the header writes.
    var people: [Person]
    var othersCount: Int
    /// "played", "is playing", "listened to", "is listening to", "watched",
    /// "is watching", "is streaming".
    var verb: String
    var isStreaming: Bool
    var title: String
    var titleDestination: Destination?
    var subtitle: String?
    var subtitleDestination: Destination?
    var artURL: URL?
    /// A game's portrait box art, drawn at its own shape.
    var artIsCover: Bool
    var artSymbol: String
    var markers: [ActivityMarker]
    var liveSince: Date?
    var occurredAt: Date?
    var corner: Corner?
    var storeOffers: [GameStoreOffer]
    /// A live song's span, for the progress bar.
    var songSpan: ClosedRange<Date>?
    var voice: VoiceBar?
    var applicationID: ApplicationID?
    /// The author's presence, for Join Activity and Listen Along.
    var liveActivity: Activity?
    var canListenAlong: Bool
}

/// A face on the voice bar.
struct ActivityMarkerFace: Equatable {
    var url: URL?
    var monogram: String
}
