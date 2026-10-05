import Foundation

/// Two of Discord's synced preferences the app honours, each kept where Discord
/// keeps it — so a choice made here is the choice every other client of the
/// account sees, and one made there arrives here.
public struct SyncedPreferences: Hashable, Sendable {
    /// "Open threads in split view" — `text_and_images.use_thread_sidebar`.
    /// On unless switched off, which is Discord's own default.
    public var opensThreadsInSplitView: Bool
    /// "Don't show this again" on an ignored person's profile —
    /// `safety_settings.ignore_profile_speedbump_disabled`.
    public var skipsIgnoredProfileWarning: Bool

    public init(opensThreadsInSplitView: Bool = true, skipsIgnoredProfileWarning: Bool = false) {
        self.opensThreadsInSplitView = opensThreadsInSplitView
        self.skipsIgnoredProfileWarning = skipsIgnoredProfileWarning
    }

    /// What one settings blob says about them. **Nil where the blob does not
    /// carry the message the preference lives in** — a live update is partial,
    /// and reading an absent message as its default would undo the reader's
    /// choice every time anything else in their settings changed.
    public struct Delta: Hashable, Sendable {
        public var opensThreadsInSplitView: Bool?
        public var skipsIgnoredProfileWarning: Bool?

        public init(opensThreadsInSplitView: Bool? = nil, skipsIgnoredProfileWarning: Bool? = nil) {
            self.opensThreadsInSplitView = opensThreadsInSplitView
            self.skipsIgnoredProfileWarning = skipsIgnoredProfileWarning
        }
    }

    public mutating func apply(_ delta: Delta) {
        if let value = delta.opensThreadsInSplitView { opensThreadsInSplitView = value }
        if let value = delta.skipsIgnoredProfileWarning { skipsIgnoredProfileWarning = value }
    }
}
