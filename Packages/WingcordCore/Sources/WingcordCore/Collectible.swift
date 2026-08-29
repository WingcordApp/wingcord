import Foundation

/// What `GET /collectibles-products/{sku}` came back with.
///
/// **One route answers for several kinds of thing**, and the kinds are not
/// variations on each other: a profile effect is an animated timeline drawn
/// inside a card, a profile frame is a pair of stills anchored to its edges.
/// Returning a single optional effect from that route is what made a frame
/// invisible — the request succeeded, the payload was complete, and the decode
/// produced nothing because it was looking for an `effects` array a frame does
/// not have.
///
/// Nameplates and avatar decorations are deliberately absent: both are named
/// directly on the user object with a CDN path, so neither needs this route,
/// and taking either from two places would be two answers that can disagree.
public enum Collectible: Hashable, Sendable {
    case effect(ProfileEffect)
    case frame(ProfileFrame)

    public var skuID: String {
        switch self {
        case .effect(let effect): effect.skuID
        case .frame(let frame): frame.skuID
        }
    }
}
