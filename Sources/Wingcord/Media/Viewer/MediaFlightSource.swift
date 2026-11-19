import AppKit
import SwiftUI
import WingcordCore

/// A SwiftUI picture the viewer can fly out of and back into — the full
/// profile's avatar and banner (docs/BETA3.md §7, R13–R14).
///
/// **An AppKit view behind the picture**, asked for its frame in window
/// coordinates when the viewer opens and again when it closes, exactly as the
/// transcript's canvas answers for its thumbnails (`MediaSources`). It never
/// takes a click: the picture's own button does.
struct MediaFlightSource: NSViewRepresentable {
    var key: MediaSources.Key
    var cornerRadius: CGFloat
    var cropsToFill: Bool
    /// Whether the picture is out of its place — in the air or on stage — so
    /// its owner leaves the place empty and there is never a second copy.
    @Binding var isLifted: Bool

    func makeNSView(context: Context) -> MediaFlightAnchorView {
        MediaFlightAnchorView()
    }

    func updateNSView(_ view: MediaFlightAnchorView, context: Context) {
        view.key = key
        view.cornerRadius = cornerRadius
        view.cropsToFill = cropsToFill
        let binding = $isLifted
        view.onLift = { lifted in
            if binding.wrappedValue != lifted { binding.wrappedValue = lifted }
        }
    }

    static func dismantleNSView(_ view: MediaFlightAnchorView, coordinator: ()) {
        view.leave()
    }
}

/// The view `MediaFlightSource` puts behind a picture.
final class MediaFlightAnchorView: NSView {
    var key: MediaSources.Key?
    var cornerRadius: CGFloat = 0
    var cropsToFill = true
    var onLift: ((Bool) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { leave() } else { join() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func join() {
        MediaSources.shared.register(self, provider: MediaSources.Provider(
            origin: .profile,
            thumbnail: { [weak self] key in
                guard let self, key == self.key, let window = self.window else { return nil }
                return MediaSources.Thumbnail(
                    frame: self.convert(self.bounds, to: nil),
                    cornerRadius: self.cornerRadius,
                    cropsToFill: self.cropsToFill,
                    window: window
                )
            },
            lift: { [weak self] key in
                guard let self else { return }
                self.onLift?(key != nil && key == self.key)
            }
        ))
    }

    func leave() {
        MediaSources.shared.unregister(self)
    }
}

extension AppModel {
    /// The full profile's avatar or banner in the viewer, flown out of its
    /// place (docs/BETA3.md §7, R13–R14): at full size, the moving one where it
    /// moves, and back into its place on the way out.
    func openProfilePicture(_ picture: ProfilePicture, of profile: ProfilePresentation) {
        let shown = picture == .avatar ? profile.avatarURL : profile.bannerURL
        guard let shown else { return }
        // 1024 for a face and 2048 for a banner: sharp at the viewer's size,
        // and the viewer caps a picture at its own pixels — the CDN's 4096 is
        // an upscale that would fill the window with a 128-pixel avatar.
        let full = Self.fullSizePicture(shown, side: picture == .avatar ? 1_024 : 2_048)
        let filename = full.lastPathComponent.isEmpty ? "picture.png" : full.lastPathComponent
        let ext = (filename as NSString).pathExtension.lowercased()
        let type = switch ext {
        case "gif": "image/gif"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        default: "image/png"
        }
        // The picture's shape, so the stage opens at it before the bytes land:
        // an avatar is square, a profile's banner 17:6.
        let size = picture == .avatar ? (1_024, 1_024) : (2_048, 723)
        let attachment = Attachment(
            id: AttachmentID(rawValue: EmbedPicture.stableID(full.absoluteString)),
            filename: filename,
            url: full.absoluteString,
            proxyURL: full.absoluteString,
            contentType: type,
            width: size.0,
            height: size.1
        )
        guard let item = MediaItem(
            attachment,
            posterWidth: picture == .avatar ? 160 : 440,
            // The URL the profile drew, so the flight starts on the picture
            // already decoded rather than on nothing.
            posterURL: shown,
            attachmentIndex: picture.sourceIndex
        ) else { return }
        mediaViewer = MediaViewerRequest(
            items: [item],
            index: 0,
            messageID: picture.sourceKey(for: profile.userID).messageID,
            channelID: nil,
            origin: .profile,
            authorName: profile.displayName,
            sentAt: .now,
            isAboveSheets: true
        )
    }

    /// The same picture asked for at `side` pixels, where its link carries a
    /// size at all (a default avatar's doesn't, and comes as it is).
    nonisolated static func fullSizePicture(_ url: URL, side: Int) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "size" }) == true
        else { return url }
        components.queryItems = components.queryItems?.map {
            $0.name == "size" ? URLQueryItem(name: "size", value: String(side)) : $0
        }
        return components.url ?? url
    }
}

/// Which of a profile's pictures the viewer shows.
enum ProfilePicture: Hashable, Sendable {
    case avatar, banner

    /// Its place in the flight's index space: far past a message's own, a
    /// forward's and an embed's, though the profile is a surface of its own.
    var sourceIndex: Int { self == .avatar ? 30_000 : 30_001 }

    /// The key a profile's surface answers the flight with. The person stands
    /// where a message would: the profile is its own origin, so the two never
    /// meet.
    func sourceKey(for userID: UserID) -> MediaSources.Key {
        MediaSources.Key(messageID: MessageID(rawValue: userID.rawValue), attachmentIndex: sourceIndex)
    }
}
