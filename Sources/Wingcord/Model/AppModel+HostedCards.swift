import CoreGraphics
import WingcordCore

// MARK: - Hosted cards in messages

extension AppModel {

    /// A hosted card measured itself. The transcript reserves exactly this,
    /// and is asked to look again only when it moved by a whole point.
    func noteHostedCardSize(_ size: CGSize, for key: HostedCardKey) {
        let whole = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard whole.height > 0, hostedCardSizes[key, default: HostedCardMeasure()].note(whole) else { return }
        cardRevision &+= 1
    }
}
