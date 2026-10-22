import Foundation

// MARK: - What a Focus does to the reader's status
//
// A macOS Focus reaches Wingcord as a Focus filter: the system calls the app
// with the filter's parameters when the Focus comes on, and **calls it again
// with the parameters' default values when the Focus goes off** — measured on a
// real Focus, 2026-10-20 (docs/CLIPS-PRESENCE.md, Phase 0.2). The defaults
// therefore mean "nothing asked of Wingcord", and an empty request is the end
// of a Focus.
//
// Everything here is pure: what to change as a Focus begins, and what to put
// back as it ends, given what is on the account now and what the Focus changed
// before. The app applies the answer and keeps the takeover across launches,
// because the call that ends a Focus can arrive in a process that never saw the
// one that began it.

/// What a Focus asks of the reader's presence.
public struct FocusRequest: Hashable, Sendable {
    /// The status to wear while the Focus is on. Nil leaves it alone.
    public var status: PresenceStatus?
    /// The custom status to wear. Nil leaves it alone.
    public var customStatus: CustomStatus?

    public init(status: PresenceStatus? = nil, customStatus: CustomStatus? = nil) {
        self.status = status
        self.customStatus = customStatus.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Nothing asked — which is also what the call that ends a Focus carries.
    public var isEmpty: Bool { status == nil && customStatus == nil }
}

/// What a Focus changed, so its end can undo exactly that and nothing more.
///
/// **Before and after, for each half.** The end of a Focus puts a value back
/// only while the account still shows what the Focus put there: a status the
/// reader changed by hand in the meantime is theirs, and the end of a Focus
/// must not overwrite it.
public struct FocusTakeover: Hashable, Sendable, Codable {
    public struct Status: Hashable, Sendable, Codable {
        public var before: PresenceStatus
        public var applied: PresenceStatus
    }

    public struct Custom: Hashable, Sendable, Codable {
        public var before: CustomStatus?
        public var applied: CustomStatus
    }

    public var status: Status?
    public var custom: Custom?

    public init(status: Status? = nil, custom: Custom? = nil) {
        self.status = status
        self.custom = custom
    }

    public var isEmpty: Bool { status == nil && custom == nil }
}

/// A change to the custom status, where "leave it" and "clear it" differ.
public enum CustomStatusChange: Hashable, Sendable {
    case keep
    /// Write this one; nil clears it.
    case set(CustomStatus?)
}

/// What to write to the account, and what to remember afterwards.
public struct FocusChanges: Hashable, Sendable {
    /// The status to set, or nil to leave it.
    public var status: PresenceStatus?
    public var customStatus: CustomStatusChange
    /// What the Focus has changed once these are applied; nil when nothing is.
    public var takeover: FocusTakeover?

    public init(status: PresenceStatus? = nil, customStatus: CustomStatusChange = .keep, takeover: FocusTakeover?) {
        self.status = status
        self.customStatus = customStatus
        self.takeover = takeover
    }

    public var changesNothing: Bool {
        status == nil && customStatus == .keep
    }
}

public enum FocusPlan {

    /// The changes for a Focus that has come on, or switched to another Focus.
    ///
    /// **Invisible is never raised.** A reader who chose to appear offline and
    /// then started a Focus asking for Do Not Disturb would otherwise be shown
    /// online to everybody — the Focus is about being interrupted less, never
    /// about being seen more. Invisible is left alone unless the Focus itself
    /// put it there.
    ///
    /// **A second Focus keeps the first one's "before".** Switching from Work to
    /// Gaming changes what is applied, but what goes back at the very end is
    /// what the reader had before any Focus touched it — unless the reader
    /// changed it by hand in between, in which case their choice is the new
    /// "before". A Focus that asks for less than the one before it gives back
    /// what it no longer asks for.
    public static func begin(
        _ request: FocusRequest,
        currentStatus: PresenceStatus,
        currentCustomStatus: CustomStatus?,
        existing: FocusTakeover?,
        now: Date = .now
    ) -> FocusChanges {
        guard !request.isEmpty else {
            return end(
                currentStatus: currentStatus,
                currentCustomStatus: currentCustomStatus,
                existing: existing,
                restores: true,
                now: now
            )
        }
        var takeover = existing ?? FocusTakeover()
        var changes = FocusChanges(takeover: nil)

        if let wanted = request.status {
            let ownInvisible = currentStatus == .invisible && takeover.status?.applied != .invisible
            if !ownInvisible {
                let before = takeover.status.map { currentStatus == $0.applied ? $0.before : currentStatus }
                    ?? currentStatus
                takeover.status = .init(before: before, applied: wanted)
                if currentStatus != wanted { changes.status = wanted }
            }
        } else if let previous = takeover.status {
            if currentStatus == previous.applied, currentStatus != previous.before {
                changes.status = previous.before
            }
            takeover.status = nil
        }

        let current = currentCustomStatus?.current(at: now)
        if let wanted = request.customStatus {
            let before = takeover.custom.map { Self.same(current, $0.applied) ? $0.before : current } ?? current
            takeover.custom = .init(before: before, applied: wanted)
            if !Self.same(current, wanted) { changes.customStatus = .set(wanted) }
        } else if let previous = takeover.custom {
            if Self.same(current, previous.applied) {
                changes.customStatus = .set(previous.before?.current(at: now))
            }
            takeover.custom = nil
        }

        changes.takeover = takeover.isEmpty ? nil : takeover
        return changes
    }

    /// The changes for a Focus that has ended.
    ///
    /// With `restores` off, nothing is put back and the takeover is simply
    /// forgotten — the reader's status stays as the Focus left it.
    public static func end(
        currentStatus: PresenceStatus,
        currentCustomStatus: CustomStatus?,
        existing: FocusTakeover?,
        restores: Bool,
        now: Date = .now
    ) -> FocusChanges {
        guard let existing, restores else { return FocusChanges(takeover: nil) }
        var changes = FocusChanges(takeover: nil)
        if let status = existing.status, currentStatus == status.applied, status.applied != status.before {
            changes.status = status.before
        }
        if let custom = existing.custom, Self.same(currentCustomStatus?.current(at: now), custom.applied) {
            changes.customStatus = .set(custom.before?.current(at: now))
        }
        return changes
    }

    /// Whether the account still shows a custom status. **Text and emoji, not
    /// expiry** — the expiry is when the status lapses, not what it says.
    static func same(_ lhs: CustomStatus?, _ rhs: CustomStatus?) -> Bool {
        lhs?.text == rhs?.text && lhs?.emoji == rhs?.emoji
    }
}
