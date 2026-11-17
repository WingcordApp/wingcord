import Foundation
import WingcordCore

/// Something a running activity asked to share (decision 7): its Invite
/// (`OPEN_INVITE_DIALOG`), a link back into it (`SHARE_LINK`), or a picture it
/// made (`OPEN_SHARE_MOMENT_DIALOG`). Shown in the forward sheet: copy, or
/// pick conversations and send.
@MainActor
final class ActivityShareRequest: Identifiable {
    enum Kind {
        /// An invite that opens the activity for whoever follows it.
        case invite
        /// The app's own words, with its link.
        case link(message: String)
        /// A picture on Discord's CDN.
        case moment(imageURL: URL)
    }

    let id = UUID()
    let kind: Kind
    let applicationID: ApplicationID
    let appName: String
    let iconURL: URL?
    /// What is copied and sent: the invite, the activity link or the picture.
    let link: String
    private(set) var didCopy = false
    private(set) var didSend = false
    /// The app's answer, sent once when the sheet goes.
    private var finish: ((_ didCopy: Bool, _ didSend: Bool) -> Void)?

    init(
        kind: Kind, applicationID: ApplicationID, appName: String, iconURL: URL?, link: String,
        finish: ((_ didCopy: Bool, _ didSend: Bool) -> Void)? = nil
    ) {
        self.kind = kind
        self.applicationID = applicationID
        self.appName = appName
        self.iconURL = iconURL
        self.link = link
        self.finish = finish
    }

    var title: String {
        switch kind {
        case .invite: "Invite to \(appName)"
        case .link: "Share \(appName)"
        case .moment: "Share Moment"
        }
    }

    var subtitle: String? {
        switch kind {
        case .invite: "Friends who follow the link join you in \(appName)."
        case .link: nil
        case .moment: "From \(appName)"
        }
    }

    /// The message a pick sends: the app's words, the link, then the reader's.
    func message(comment: String) -> String {
        let words = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        if case .link(let message) = kind, !message.isEmpty { lines.append(message) }
        lines.append(link)
        let body = lines.joined(separator: "\n")
        return words.isEmpty ? body : "\(body)\n\n\(words)"
    }

    func copied() {
        didCopy = true
        AppModel.copy(link)
    }

    func sent() { didSend = true }

    /// Answers the app, once, however the sheet went.
    func close() {
        finish?(didCopy, didSend)
        finish = nil
    }
}
