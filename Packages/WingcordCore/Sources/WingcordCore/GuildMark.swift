import Foundation

/// The mark Discord draws beside a server's name, and what its flyout says.
///
/// **Discord's own rule, in its own order** (modules `426983` and `176128` of its
/// web bundle): staff first, then verified and partnered together, verified,
/// partnered — and only for a community, discoverable when the community is
/// also public, community otherwise. A server with none of those draws no mark.
/// Discoverable *alone* is not a mark: Discord requires `COMMUNITY` for both of
/// the community kinds, and the order means a partnered community wears the
/// partner mark rather than both.
///
/// **The boost count is part of the mark, not decoration beside it.** A boosted
/// community wears Discord's purple-to-pink rosette instead of the plain one,
/// and its flyout gains the level-and-boosts strip — one fact, two effects, so
/// it travels with the kind rather than being re-derived at each surface.
public struct GuildMark: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case staff
        case verifiedAndPartnered
        case verified
        case partnered
        /// A community that is also discoverable — the globe.
        case discoverable
        /// A community — the house.
        case community
    }

    /// Who may join, which is the flyout's last line.
    public enum Admission: Hashable, Sendable {
        /// `COMMUNITY` and `DISCOVERABLE` — Discord's `PUBLIC`.
        case anyone
        /// Manual approval behind the rules gate — `APPLY_TO_JOIN`.
        case byApplication
        /// Everything else — `INVITE_ONLY`.
        case byInvite
    }

    public var kind: Kind
    public var admission: Admission
    /// The server's boost level, 0–3. Zero where the source does not carry one:
    /// a discovery result has a count and no level, and Discord's own flyout
    /// then says "No Level" for it too.
    public var boostTier: Int
    public var boostCount: Int

    public init?(features: Set<String>, boostTier: Int = 0, boostCount: Int = 0) {
        let isCommunity = features.contains("COMMUNITY")
        let admission: Admission =
            if isCommunity && features.contains("DISCOVERABLE") {
                .anyone
            } else if features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL"),
                      features.contains("MEMBER_VERIFICATION_GATE_ENABLED") {
                .byApplication
            } else {
                .byInvite
            }
        let isVerified = features.contains("VERIFIED")
        let isPartnered = features.contains("PARTNERED")
        let kind: Kind
        if features.contains("INTERNAL_EMPLOYEE_ONLY") {
            kind = .staff
        } else if isVerified && isPartnered {
            kind = .verifiedAndPartnered
        } else if isVerified {
            kind = .verified
        } else if isPartnered {
            kind = .partnered
        } else if isCommunity {
            kind = admission == .anyone ? .discoverable : .community
        } else {
            return nil
        }
        self.kind = kind
        self.admission = admission
        self.boostTier = boostTier
        self.boostCount = boostCount
    }

    /// Discord's `premium` trait: any boost at all, or a level.
    public var isBoosted: Bool { boostCount > 0 || boostTier > 0 }

    /// Whether Discord counts this server as verified — the three kinds that
    /// wear the check.
    public var isVerified: Bool {
        switch kind {
        case .staff, .verified, .verifiedAndPartnered: true
        case .partnered, .discoverable, .community: false
        }
    }

    // MARK: The flyout's words — `F` in Discord's badge module, word for word

    public var title: String {
        kind == .staff ? "Internal Employee (Staff)" : "Community Server"
    }

    public var subtitle: String? {
        switch kind {
        case .verified: "Verified"
        case .partnered: "Discord Partner"
        case .verifiedAndPartnered: "Verified & Partnered"
        // Discord repeats the staff title on all three lines; one is the fact.
        case .staff, .discoverable, .community: nil
        }
    }

    /// Who may join. A discoverable server is open by definition, which is why
    /// Discord's own table says so without consulting the admission.
    public var detail: String? {
        switch kind {
        case .staff: nil
        case .discoverable: "Anyone can join this server."
        case .verified, .partnered, .verifiedAndPartnered, .community:
            switch admission {
            case .anyone: "Anyone can join this server."
            case .byApplication: "People must submit an application to join."
            case .byInvite: "People with an invite link can join."
            }
        }
    }

    /// The level in the boost strip (`gb` in Discord's premium helpers).
    public var boostLevel: String {
        boostTier > 0 && boostTier <= 3 ? "Level \(boostTier)" : "No Level"
    }

    /// The count in the boost strip — `dR/SVH`, "1 Boost" / "261 Boosts".
    public var boostCountLabel: String {
        boostCount == 1 ? "1 Boost" : "\(boostCount.formatted()) Boosts"
    }

    /// What the mark is called when it is read aloud — Discord's own
    /// `aria-label`, the subtitle where there is one and the title otherwise.
    public var accessibilityLabel: String { subtitle ?? title }
}
