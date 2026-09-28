import SwiftUI
import WingcordCore

// MARK: - Age groups
//
// Discord's newest account fact, read out of its bundle: the group resolves
// from `age_verification_status` (`AgeGroup`), the row sits in Account
// Standing with a NEW badge, and the category opens on a dismissible notice
// whose words depend on the group. Discord's verification itself runs through
// outside vendors this client cannot host, so the row reports and does not
// offer to change anything.

/// The notice over Account Standing: what age groups are, and the reader's.
struct AgeGroupNotice: View {
    var group: AgeGroup
    @AppStorage("settings.ageGroupNoticeDismissed") private var isDismissed = false

    var body: some View {
        if !isDismissed {
            SettingsCard {
                HStack(alignment: .top, spacing: Spacing.snug) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Palette.accent)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(SettingsType.rowLabel)
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss", systemImage: "xmark") { isDismissed = true }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Ink.secondary)
                }
                .padding(SettingsMetrics.cardContentInset)
            }
        }
    }

    /// Discord's sentence for each group (`PMznGO`, `qSkhZH`, `vGxRDB`), with
    /// its link to the post that explains it.
    private var message: AttributedString {
        let lead = switch group {
        case .adult:
            "Age groups determine if you can access content and settings meant for adults. You’re in the adult age group (18+), so nothing changes for you. "
        case .teen, .unconfirmed:
            "Age groups determine if you can access content and settings meant for adults. Otherwise, Discord works the same. See your age group below and "
        }
        let link = group == .adult ? "Learn more on our blog" : "learn more on our blog"
        var text = AttributedString(lead)
        var anchor = AttributedString(link)
        anchor.link = Self.blog
        anchor.underlineStyle = .single
        text += anchor
        if group != .adult { text += AttributedString(".") }
        return text
    }

    private static let blog = URL(string: "https://discord.com/blog/safer-for-teens-same-discord-for-adults")
}

/// "Age group [NEW] ……… Adult".
struct AgeGroupRow: View {
    var group: AgeGroup
    /// Seen once the pane has been open: the badge is news, and news that
    /// never goes away is a label.
    @AppStorage("settings.ageGroupSeen") private var isSeen = false

    var body: some View {
        HStack(spacing: Spacing.snug) {
            HStack(spacing: Spacing.tight) {
                Text("Age group").font(SettingsType.rowLabel)
                if !isSeen {
                    Text("NEW")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.tight)
                        .padding(.vertical, 1)
                        .background(Palette.accent, in: .capsule)
                }
            }
            Spacer(minLength: Spacing.base)
            Text(group.label)
                .font(SettingsType.rowLabel)
                .foregroundStyle(Ink.secondary)
        }
        .padding(.leading, SettingsMetrics.cardContentInset)
        .padding(.trailing, SettingsMetrics.controlTrailing)
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.toggleRowHeight)
        .accessibilityElement(children: .combine)
        .onDisappear { isSeen = true }
    }
}
