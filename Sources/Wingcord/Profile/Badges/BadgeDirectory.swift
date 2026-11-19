import SwiftUI
import WingcordCore

// MARK: - Every badge, and how far along each one is
//
// docs/CLIPS-PRESENCE.md, Phase 8 — Discord's badge directory (Alex's
// screenshots 4, 8 and 9): on the left the badges owned — and, for the
// reader's own, "Available to unlock" — on the right the one chosen: its
// artwork, its level in capitals, what it says, when it was unlocked and how
// rare it is, then the progress to the next level and every level there is.
// A flyout rather than a sheet, as Alex prefers them.

struct BadgeDirectory: View {
    /// Whose badges.
    var userID: UserID
    /// The badge to open on.
    var initialBadgeID: Int?
    var customize: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var selected: Int?
    /// Whose badges are showing — the person's, or after "View Your Badges"
    /// the reader's own.
    @State private var showing: UserID?

    private var shownUser: UserID { showing ?? userID }
    private var isOwn: Bool { shownUser == model.currentUserID }
    private var badges: [CatalogBadge] { model.badgeCatalogs[shownUser] ?? [] }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 300)
            Divider()
            detail
                .frame(width: 420)
        }
        .frame(height: 560)
        .task(id: shownUser) { model.loadBadgeCatalog(of: shownUser) }
        .onAppear { selected = initialBadgeID }
    }

    // MARK: The left

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.base) {
                    // Whose they are, face first, as Discord's title has it.
                    if !isOwn, let user = model.users[shownUser] {
                        AvatarView(
                            url: model.avatarURL(forUserID: user.id, inGuild: nil, side: 28),
                            monogram: user.monogram,
                            side: 28,
                            decorationURL: nil
                        )
                    }
                    Text(isOwn ? "Your badges" : "\(name)'s badges")
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(InkColor.primary)
                }
                Text(isOwn
                    ? "Browse your badges and discover new ones you can unlock."
                    : "Explore their badges, or view your badges to find out what you can unlock next.")
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.group) {
                    grid(badges.ownedAndEarnable.owned)
                    if isOwn, !badges.ownedAndEarnable.earnable.isEmpty {
                        Text("Available to unlock")
                            .font(.system(.headline))
                            .foregroundStyle(InkColor.primary)
                        grid(badges.ownedAndEarnable.earnable)
                    }
                }
            }
            Spacer(minLength: 0)
            if isOwn {
                if let customize, model.badgeManagement.enabled {
                    Button("Customize Your Badges", action: customize)
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
            } else if let me = model.currentUserID {
                Button("View Your Badges") {
                    showing = me
                    selected = nil
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(Spacing.group)
    }

    private func grid(_ items: [CatalogBadge]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: Spacing.base), count: 4), spacing: Spacing.base) {
            ForEach(items) { badge in
                Button {
                    selected = badge.badgeID
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Palette.skeletonPlate)
                        if let url = badge.mark {
                            BadgeArtwork(url: url, side: 34)
                                .opacity(badge.isOwned ? 1 : 0.55)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(current?.badgeID == badge.badgeID ? Palette.accent : .clear, lineWidth: 2)
                    }
                }
                .buttonStyle(.plain)
                .help(badge.name ?? badge.title)
                .accessibilityLabel(badge.name ?? badge.title)
            }
        }
    }

    // MARK: The right

    private var current: CatalogBadge? {
        badges.first { $0.badgeID == selected } ?? badges.ownedAndEarnable.owned.first ?? badges.first
    }

    @ViewBuilder private var detail: some View {
        if let badge = current {
            ScrollView {
                VStack(spacing: Spacing.snug) {
                    if badge.kind?.isLevelled == true {
                        Text("BETA")
                            .font(.system(.caption, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .glassEffect(.regular, in: .capsule)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    artwork(badge)
                        .frame(height: 170)
                    if let name = badge.eyebrow {
                        Text(name)
                            .font(.system(.title3, weight: .medium))
                            .foregroundStyle(InkColor.secondary)
                    }
                    Text(badge.title.uppercased())
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(InkColor.primary)
                        .multilineTextAlignment(.center)
                    facts(badge)
                    progressCard(badge)
                }
                .padding(Spacing.group)
            }
        } else {
            ContentUnavailableView("No badges yet", systemImage: "rosette")
        }
    }

    /// The chosen badge's picture. **Nitro's moves, and is the size Discord's
    /// detail makes it**: `.badgeGraphicAnimatedNitro { height: 150px }`, which is
    /// a drawing 105 across on that canvas (Alex's image 51).
    @ViewBuilder private func artwork(_ badge: CatalogBadge) -> some View {
        let film = motion.reduceMotion ? nil : badge.animatedArtwork
        if badge.kind == .premiumTenure || film != nil {
            BadgeGraphic(still: badge.artwork(reducesMotion: true), film: film, height: 105)
        } else if let url = badge.artwork(reducesMotion: true) {
            BadgeArtwork(url: url, side: 170)
        }
    }

    /// "23 hours streamed to others • Unlocked 7/30/26 • ★ MYTHIC".
    private func facts(_ badge: CatalogBadge) -> some View {
        HStack(spacing: Spacing.tight) {
            let parts = [
                badge.infoLabel,
                badge.isOwned ? badge.unlockedAt.map { "Unlocked " + $0.formatted(date: .numeric, time: .omitted) } : nil,
            ].compactMap(\.self)
            if !parts.isEmpty {
                Text(parts.joined(separator: " • "))
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.secondary)
            }
            if let rarity = badge.displayRarity, badge.isOwned {
                Label(rarity.title.uppercased(), systemImage: rarity == .mythic ? "star.fill" : "diamond.fill")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(rarityColor(rarity))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(rarityColor(rarity), lineWidth: 1.5))
            }
        }
        .multilineTextAlignment(.center)
    }

    /// Discord's arrangement (Alex's screenshots 4 and 9): **the reader's
    /// own** badge opens on "Your progress" — how far to the next level — then
    /// what the badge is for and every level; **somebody else's** opens on what
    /// it is for, then "{name}'s Progress" over the levels. One heading each,
    /// never two of the same.
    @ViewBuilder private func progressCard(_ badge: CatalogBadge) -> some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            // Discord now shows the bar for any owned badge with a next level
            // (`c9beb9de` `eC`), the Void and Gifting among them.
            if isOwn, badge.isOwned, badge.progress != nil, let next = badge.nextTier {
                Text("Your progress")
                    .font(.system(.headline))
                    .foregroundStyle(InkColor.primary)
                HStack(spacing: Spacing.snug) {
                    if let url = badge.currentTier?.simpleIconURL ?? badge.mark { BadgeArtwork(url: url, side: 30) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(remainingLine(badge, next: next))
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                        ProgressView(value: badge.fractionToNextTier)
                            .tint(Palette.accent)
                    }
                    if let url = next.simpleIconURL { BadgeArtwork(url: url, side: 30) }
                }
                Divider()
            }
            if let description = descriptionLine(badge) {
                Text(description)
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = BadgeAction(badge: badge, isOwn: isOwn, model: model) {
                Button(action.title, systemImage: action.symbol) { action.perform(model) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: badge.kind == .orbVoid ? .infinity : nil)
            }
            if badge.tiers.count > 1, !isOwn {
                Divider()
                Text("\(name)'s Progress")
                    .font(.system(.headline))
                    .foregroundStyle(InkColor.primary)
                    .padding(.top, Spacing.tight)
            }
            if badge.tiers.count > 1 {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.base), count: 4), spacing: Spacing.snug) {
                    ForEach(badge.tiers) { tier in
                        let reached = badge.isReached(tier)
                        VStack(spacing: 2) {
                            if let url = tier.simpleIconURL ?? tier.complexIconURL {
                                BadgeArtwork(url: url, side: 34)
                                    .opacity(reached ? 1 : 0.5)
                            }
                            // Discord's: the level's name with the lock
                            // beside it, then what it takes — and where a
                            // level has no name (the booster's nine), only
                            // what it takes, the lock moving beside that.
                            let levelName = badge.levelName(tier)
                            if let levelName {
                                Label {
                                    Text(levelName)
                                } icon: {
                                    if !reached { Image(systemName: "lock.fill") }
                                }
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundStyle(reached ? InkColor.primary : InkColor.secondary)
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                            }
                            if let milestone = tier.milestoneText {
                                Label {
                                    Text(milestone)
                                } icon: {
                                    if !reached, levelName == nil { Image(systemName: "lock.fill") }
                                }
                                .font(levelName == nil ? .system(.caption, weight: .semibold) : .system(.caption))
                                .foregroundStyle(levelName == nil && reached ? InkColor.primary : InkColor.secondary)
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            }
                        }
                    }
                }
            }
        }
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.skeletonPlate.opacity(0.6), in: .rect(cornerRadius: 18, style: .continuous))
    }

    /// What the badge is for — or, for a badge at its top level, Discord's
    /// line for that (`49253.JV`).
    private func descriptionLine(_ badge: CatalogBadge) -> String? {
        if isOwn, badge.isOwned, !badge.tiers.isEmpty, badge.nextTier == nil {
            return "You\u{2019}ve maxed out this badge. Sit back, relax, and enjoy the view from the top."
        }
        return badge.description
    }

    /// "52 more hours" — Discord's line — where the next level's milestone
    /// counts in the progress's own unit; "Next: 1 year" where it does not
    /// (Nitro counts months towards a level named in years).
    private func remainingLine(_ badge: CatalogBadge, next: BadgeTier) -> String {
        let remaining = Int(badge.remainingToNextTier.rounded(.up))
        guard let milestone = next.milestoneText,
              let threshold = badge.progress?.threshold,
              let (number, unit) = Self.milestone(milestone),
              number == Int(threshold.rounded())
        else { return next.milestoneText.map { "Next: \($0)" } ?? "\(remaining) more" }
        let word = remaining == 1 && unit.hasSuffix("s") ? String(unit.dropLast()) : unit
        return "\(remaining.formatted()) more \(word)"
    }

    /// "1,000 hours" → (1000, "hours").
    private static func milestone(_ text: String) -> (Int, String)? {
        let parts = text.split(separator: " ", maxSplits: 1)
        guard parts.count == 2,
              let number = Int(parts[0].replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: ""))
        else { return nil }
        var unit = String(parts[1])
        if number != 1, !unit.hasSuffix("s") { unit += "s" }
        return (number, unit)
    }

    private func rarityColor(_ rarity: BadgeRarity) -> Color {
        switch rarity {
        case .common: Color(hex: 0x9DA3AE)
        case .rare: Color(hex: 0x4F9DFF)
        case .epic: Color(hex: 0xA37BFF)
        case .legendary: Color(hex: 0xFFB340)
        case .mythic: Color(hex: 0xFF9B3E)
        }
    }

    private var name: String {
        model.users[shownUser]?.preferredName ?? "Their"
    }
}
