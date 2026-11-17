/// Where asking Discord for its Nitro Emoji Packs stands.
///
/// **Four answers, because the page says something different for each.** A
/// 404 is Discord saying packs are not enabled for this account (its own
/// client logs exactly that); a failure is a request that did not land, and
/// says so with a retry; an empty list is neither.
enum EmojiPacksLoad: Equatable, Sendable {
    case idle
    case loading
    case loaded
    /// `GET /emoji-packs` answered 404.
    case notEnabled
    case failed
}
