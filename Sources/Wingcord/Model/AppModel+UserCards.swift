import CoreGraphics
import WingcordCore

// MARK: - Profile cards in messages

extension AppModel {

    /// A profile card measured itself. The transcript reserves exactly this,
    /// and is asked to look again only when it moved by a whole point.
    func noteUserCardSize(_ size: CGSize, for key: UserCardKey) {
        let whole = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard whole.height > 0, userCardSizes[key] != whole else { return }
        userCardSizes[key] = whole
        cardRevision &+= 1
    }
}
