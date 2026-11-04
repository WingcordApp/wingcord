import AppKit
import SwiftUI
import WingcordCore

/// The Boost progress bar — Discord's `GuildPowerupsProgressBarUI`
/// (`35a17d…`, stylesheet `b8870b…`): a 26-point track at the head of the
/// channels, "Boost Goal" on the left, "9/39 Boosts ›" on the right, and a pink
/// fill between them.
///
/// **The fill starts where the reader last saw it**, as Discord's does — the
/// count each server's bar last drew is kept (`BoostGoalMemory`), so a server
/// that gained boosts since shows the fill moving to the new count instead of
/// simply being longer. It moves on `Motion.reposition` rather than Discord's
/// bouncy spring (D9): the bar is a reading, and a reading that overshoots says
/// a number that is not true for a moment.
///
/// **A click opens the server's boost level** (`BoostGoalFlyout`), read-only —
/// Discord's click opens its boosting page, which sells boosts this client
/// does not. **A secondary click offers Discord's one switch** to the people
/// Discord offers it to.
///
/// One row per list, so the popover beside it is the voice strip's exception
/// to the no-presentation-per-row rule (`INVARIANTS.md`), not a new one.
struct SidebarBoostGoalRow: View {
    var goal: SidebarBoostGoal
    /// Discord's "Enable Progress Bar", from the bar's own menu.
    var setEnabled: (Bool) -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false
    @State private var isFlyoutShown = false
    /// The count the fill is drawn at while it travels from the one last
    /// seen; nil once it rests on the server's own.
    @State private var travelling: Int?

    /// Discord's `rgba(255, 115, 250)`.
    static let pink = Color(red: 1, green: 115 / 255, blue: 250 / 255)
    static let height: CGFloat = 26
    /// The fill sits 2 points inside the track all round.
    static let inset: CGFloat = 2

    var body: some View {
        Button {
            isFlyoutShown = true
        } label: {
            bar
        }
        .buttonStyle(.plain)
        // The track runs to the rows' highlight edges, not their content's.
        .padding(.horizontal, SidebarRowGeometry.highlightOutset.leading)
        .padding(.top, Spacing.hair)
        .padding(.bottom, Spacing.base)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .onSecondaryClick { _ in
            guard goal.canSwitchOff else { return }
            BoostGoalMenu.show { setEnabled(false) }
        }
        .popover(isPresented: $isFlyoutShown, arrowEdge: .trailing) {
            BoostGoalFlyout(goal: goal)
                // The popover's glass is the flyout's body — §4.9.
                .presentationBackground(.clear)
        }
        .onAppear { travel() }
        .onChange(of: goal.count) { travel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Boost Goal"))
        .accessibilityValue(Text(SidebarBoostGoal.countLabel(goal.count, goal: goal.goal)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Disable Progress Bar")) {
            if goal.canSwitchOff { setEnabled(false) }
        }
    }

    private var bar: some View {
        let shown = travelling ?? goal.count
        let fraction = goal.goal > 0 ? min(Double(shown) / Double(goal.goal), 1) : 0
        return ZStack {
            // Discord's hover breathes the track, not the words over it:
            // 2 per cent wider, 10 per cent taller.
            track(fraction: fraction)
                .scaleEffect(x: isHovering ? 1.02 : 1, y: isHovering ? 1.1 : 1)
            labels
        }
        .frame(height: Self.height)
        .contentShape(.capsule)
    }

    private func track(fraction: Double) -> some View {
        Capsule()
            .fill(Palette.hoverFill)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    let inner = max(proxy.size.width - Self.inset * 2, 0)
                    let side = proxy.size.height - Self.inset * 2
                    let width = inner * fraction
                    fill(side: side)
                        // A capsule never narrower than it is tall, cut to the
                        // fill's width: a sliver keeps its round start and a
                        // straight end, Discord's `progressLow`.
                        .frame(width: max(width, side), height: side)
                        .frame(width: width, alignment: .leading)
                        .clipped()
                        .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
                        .padding(Self.inset)
                }
            }
    }

    private func fill(side: CGFloat) -> some View {
        Capsule()
            .fill(LinearGradient(
                colors: [Self.pink.opacity(isHovering ? 0.25 : 0.1), Self.pink.opacity(isHovering ? 0.7 : 0.4)],
                startPoint: .leading,
                endPoint: .trailing
            ))
            // Discord's inner glow, `inset 0 0 4.6px` of the same pink.
            .overlay {
                Capsule()
                    .stroke(Self.pink.opacity(0.35), lineWidth: 3)
                    .blur(radius: 2.3)
                    .clipShape(.capsule)
            }
    }

    private var labels: some View {
        HStack(spacing: Spacing.base) {
            HStack(spacing: Spacing.hair) {
                Text("Boost Goal")
                    .lineLimit(1)
                if goal.isReached {
                    Text(verbatim: "🎉")
                        .transition(.scale.combined(with: .opacity))
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: Spacing.hair) {
                Text(SidebarBoostGoal.countLabel(goal.count, goal: goal.goal))
                    .lineLimit(1)
                    .contentTransition(.numericText(value: Double(goal.count)))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    // The way in leans toward it under the pointer.
                    .offset(x: isHovering ? 1.5 : 0)
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Ink.primary)
        .padding(.horizontal, Spacing.base)
        .animation(motion.standard, value: goal.isReached)
        .animation(motion.standard, value: goal.count)
    }

    /// Draws the fill at the count last seen and moves it to the server's own.
    private func travel() {
        let seen = BoostGoalMemory.count(for: goal.guildID) ?? 0
        BoostGoalMemory.remember(goal.count, for: goal.guildID)
        guard seen != goal.count else { return }
        travelling = seen
        // A turn later, or both writes land in one transaction and the fill
        // is simply drawn at the end.
        Task { @MainActor in
            withAnimation(motion.reposition) { travelling = nil }
        }
    }
}

/// What a server's bar last drew, per server — Discord's
/// `PremiumGuildProgressBarPersistedStore`, which its bar animates from.
enum BoostGoalMemory {
    private static let key = "boostGoalSeenCounts"
    private static var counts: [String: Int] =
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]

    static func count(for guildID: GuildID) -> Int? {
        counts[String(guildID.rawValue)]
    }

    static func remember(_ count: Int, for guildID: GuildID) {
        let id = String(guildID.rawValue)
        guard counts[id] != count else { return }
        counts[id] = count
        UserDefaults.standard.set(counts, forKey: key)
    }
}

/// The bar's menu — Discord's "Progress Bar Actions" (`709843`): one checked
/// item, which takes the bar away.
enum BoostGoalMenu {
    static func show(disable: @escaping @MainActor () -> Void) {
        let menu = NSMenu()
        let item = ActionMenuItem("Enable Progress Bar", handler: disable)
        item.state = .on
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// A server's boost level, from its Boost progress bar: the level, how far to
/// the next one, and what this one gives.
///
/// **No purchase and no upsell.** Discord's click opens a page that sells
/// boosts; this answers the question the bar raises — where the server stands.
struct BoostGoalFlyout: View {
    var goal: SidebarBoostGoal

    static let width: CGFloat = 300

    var body: some View {
        let perks = BoostLevelPerks(level: goal.level)
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(spacing: Spacing.base) {
                BoostGemChip(side: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(goal.level > 0 ? "Level \(goal.level)" : "No Level")
                        .font(.system(.headline))
                        .foregroundStyle(Ink.primary)
                    Text(goal.count == 1 ? "1 Boost" : "\(goal.count.formatted()) Boosts")
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: Spacing.tight) {
                BoostLevelTrack(count: goal.count)
                Text(nextLevelLine)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 0) {
                ForEach(perks.stats, id: \.label) { stat in
                    VStack(spacing: 0) {
                        Text(stat.value)
                            .font(.system(.title3, weight: .bold))
                            .foregroundStyle(Ink.primary)
                            .monospacedDigit()
                        Text(stat.label)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, Spacing.base)
            .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.row, style: .continuous))

            FlowLayout(spacing: Spacing.tight) {
                ForEach(perks.features, id: \.title) { feature in
                    Label(feature.title, systemImage: feature.symbolName)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, Spacing.base)
                        .padding(.vertical, Spacing.tight)
                        .background(Palette.hoverFill, in: .capsule)
                }
            }

            Text(goalLine)
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.margin)
        .frame(width: Self.width, alignment: .leading)
    }

    private var goalLine: String {
        goal.isReached
            ? "Enough boosts for Level 3 and every power-up."
            : "The Boost Goal is Level 3 plus every power-up — \(goal.count.formatted()) of \(goal.goal.formatted()) boosts so far."
    }

    private var nextLevelLine: String {
        guard let next = goal.nextLevel else { return "Every level is unlocked." }
        switch next.wanted {
        case 0: return "Level \(next.level) is on its way."
        case 1: return "One more boost reaches Level \(next.level)."
        default: return "\(next.wanted) more boosts reach Level \(next.level)."
        }
    }
}

/// The road to level 3: three stops, evenly spaced, at Discord's 2, 7 and 14
/// boosts, and the gradient of Discord's boost badge as far as the server has
/// come.
private struct BoostLevelTrack: View {
    var count: Int

    @Environment(\.motion) private var motion
    @State private var isShown = false

    static let thresholds = SidebarBoostGoal.levelThresholds

    var body: some View {
        let position = SidebarBoostGoal.roadPosition(of: count)
        VStack(spacing: Spacing.tight) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hoverFill)
                        .frame(height: 6)
                    Capsule()
                        .fill(BoostGemChip.gradient)
                        .frame(width: max(width * (isShown ? position : 0), 0), height: 6)
                    ForEach(1...3, id: \.self) { level in
                        let reached = count >= Self.thresholds[level]
                        // A stop not reached yet is the track's own grey, a
                        // step darker; a reached one is lit.
                        Circle()
                            .fill(reached ? AnyShapeStyle(Color.white) : AnyShapeStyle(Palette.edgeStrong))
                            .frame(width: 10, height: 10)
                            .offset(x: width * Double(level) / 3 - (level == 3 ? 10 : 5))
                    }
                }
            }
            .frame(height: 10)

            HStack(spacing: 0) {
                ForEach(1...3, id: \.self) { level in
                    Text("Level \(level)")
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(count >= Self.thresholds[level] ? Ink.primary : Ink.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .onAppear {
            withAnimation(motion.reposition) { isShown = true }
        }
    }
}

/// The boost gem in a disc of Discord's boost gradient.
struct BoostGemChip: View {
    var side: CGFloat

    /// `PREMIUM_GUILD_BADGE_V2_BACKGROUND`.
    static let gradient = LinearGradient(
        colors: [Color(cgColor: GuildMarkArt.boostPurple), Color(cgColor: GuildMarkArt.boostPink)],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        Canvas { context, size in
            let inset = size.height * 0.2
            context.withCGContext { cg in
                GuildMarkArt.drawBoostGem(in: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset), context: cg)
            }
        }
        .frame(width: side, height: side)
        .background(Self.gradient, in: .circle)
        .accessibilityHidden(true)
    }
}

/// What a boost level gives everybody in the server — Discord's per-level
/// table (`202541`'s `TG`), through the tables this app already keeps.
struct BoostLevelPerks {
    struct Stat { var value: String; var label: String }
    struct Feature { var title: String; var symbolName: String }

    var stats: [Stat]
    var features: [Feature]

    init(level: Int) {
        stats = [
            Stat(value: ExpressionSlots.emoji(premiumTier: level).formatted(), label: "Emoji"),
            Stat(value: ExpressionSlots.stickers(premiumTier: level).formatted(), label: "Stickers"),
            Stat(value: ExpressionSlots.soundboard(premiumTier: level).formatted(), label: "Sounds"),
            Stat(value: "\(BoostTier.maximumBitrate(premiumTier: level, features: []) / 1000)", label: "kbps"),
        ]
        var features: [Feature] = []
        // Streams: 720p at 30 to start, 60 from level 1, 1080p from level 2.
        features.append(Feature(
            title: level >= 2 ? "1080p 60fps streams" : level == 1 ? "720p 60fps streams" : "720p 30fps streams",
            symbolName: "play.display"
        ))
        let upload = AttachmentLimits.bytes(forGuildBoost: level)
        features.append(Feature(
            title: "\(max(upload, AttachmentLimits.bytes(forPremium: .none)) / AttachmentLimits.mebibyte) MB uploads",
            symbolName: "arrow.up.doc.fill"
        ))
        for perk in BoostTier.Perk.allCases where level >= perk.level {
            features.append(Feature(title: perk.title, symbolName: perk.symbolName))
        }
        self.features = features
    }
}

private extension BoostTier.Perk {
    var title: String {
        switch self {
        case .inviteSplash: "Invite background"
        case .animatedIcon: "Animated icon"
        case .banner: "Server banner"
        case .roleIcons: "Role icons"
        case .animatedBanner: "Animated banner"
        case .vanityURL: "Custom invite link"
        }
    }

    var symbolName: String {
        switch self {
        case .inviteSplash: "photo.on.rectangle"
        case .animatedIcon: "sparkles"
        case .banner: "rectangle.inset.filled"
        case .roleIcons: "person.crop.square.badge.camera"
        case .animatedBanner: "sparkles.rectangle.stack"
        case .vanityURL: "link"
        }
    }
}
