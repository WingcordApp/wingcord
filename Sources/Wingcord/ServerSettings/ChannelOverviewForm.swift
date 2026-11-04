import SwiftUI
import WingcordCore

/// A channel's Overview page — Discord's own controls, labels and lines, on a
/// draft the caller owns.
///
/// **Every line under a control is Discord's** (`13eee04b11ba2913`): the
/// slowmode sentence changes with the kind of channel, the visibility choices
/// carry their own paragraphs, and the region override explains itself. A
/// paraphrase reads as a different app — see the copy memory.
///
/// **What a kind of channel shows is decided by the value, not by the view.**
/// `ChannelOverview.isTextLike` and `isVoice` are the two questions, and the
/// encoder asks the same two, so the page cannot show a control whose field is
/// never sent or send a field whose control was never shown.
struct ChannelOverviewForm: View {
    @Binding var overview: ChannelOverview
    /// The server's bitrate ceiling — `BoostTier.maximumBitrate`.
    var maximumBitrate: Int
    /// Regions this channel may be pinned to. Empty until the route answers,
    /// and the picker then offers Automatic alone.
    var regions: [VoiceRegion]
    /// Whether the server takes channel summaries at all. Discord shows the
    /// switch only where they exist; a switch for a feature the server does not
    /// have is a control with nothing behind it (`INVARIANTS.md` §5.5).
    var offersSummaries: Bool

    private var isCategory: Bool { overview.kind == .category }
    private var isForum: Bool { overview.kind == .forum || overview.kind == .media }

    var body: some View {
        SheetField(title: isCategory ? "Category Name" : "Channel Name", isRequired: true) {
            TextField("", text: $overview.name)
                .modalField()
                .accessibilityLabel(Text(isCategory ? "Category Name" : "Channel Name"))
        }

        if overview.isTextLike {
            topic
            slowmode
            visibility
            if overview.kind == .text || overview.kind == .announcement {
                announcement
            }
            hideAfterInactivity
            if offersSummaries {
                flagToggle(
                    "Enable Channel Summaries",
                    detail: nil,
                    flag: .summariesDisabled,
                    isOnWhenSet: false
                )
            }
            flagToggle(
                "Show Option to Save and Copy Embedded Media",
                detail: "Allows members to save, copy, and share media attachments uploaded to "
                    + "this channel. However, files that cannot be embedded can still be downloaded.",
                flag: .hideMediaDownloadOptions,
                isOnWhenSet: false
            )
        }

        if overview.isVoice {
            slowmode
            visibility
            bitrate
            videoQuality
            userLimit
            regionOverride
        }
    }

    // MARK: Text

    private var topicLimit: Int { isForum ? 4096 : 1024 }

    private var topic: some View {
        SheetField(title: isForum ? "Post Guidelines" : "Channel Topic") {
            VStack(alignment: .trailing, spacing: Spacing.tight) {
                TextField(
                    "Let everyone know how to use this channel!",
                    text: Binding(
                        get: { overview.topic },
                        set: { overview.topic = String($0.prefix(topicLimit)) }
                    ),
                    axis: .vertical
                )
                .modalField()
                .lineLimit(3...8)
                // Discord's counter is the room left, not the room used.
                Text("\(topicLimit - overview.topic.count)")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .monospacedDigit()
                    .accessibilityLabel(Text("\(topicLimit - overview.topic.count) characters left"))
            }
        }
    }

    private var slowmodeDetail: String {
        switch overview.kind {
        case .forum, .media:
            "Members will be restricted to creating one post per this interval, unless they "
                + "have the Bypass Slowmode permission."
        case .voice, .stage:
            "Members will be restricted to sending one message per this interval, unless they "
                + "have the Bypass Slowmode permission."
        default:
            "Members will be restricted to sending one message and creating one thread per "
                + "this interval, unless they have the Bypass Slowmode permission."
        }
    }

    private var slowmode: some View {
        SheetField(title: "Slowmode", detail: slowmodeDetail) {
            FlyoutPicker(
                selection: $overview.slowmodeSeconds,
                options: SlowmodeChoices.choices(including: overview.slowmodeSeconds),
                title: SlowmodeChoices.title,
                accessibilityTitle: "Slowmode"
            )
        }
    }

    private var visibility: some View {
        SheetField(title: "Content Visibility") {
            VStack(alignment: .leading, spacing: Spacing.base) {
                ForEach(ChannelVisibility.allCases) { candidate in
                    RadioChoice(
                        title: candidate.title,
                        detail: candidate.detail,
                        isSelected: overview.visibility == candidate
                    ) {
                        overview.visibility = candidate
                    }
                }
            }
        }
    }

    private var announcement: some View {
        SheetField(
            title: "Announcement Channel",
            detail: "By creating an announcement channel, your server profile will be visible to "
                + "others outside your server members. You can control Profile privacy in Server "
                + "Settings > Profile."
        ) {
            Toggle(
                "Announcement Channel",
                isOn: Binding(
                    get: { overview.kind == .announcement },
                    // The switch **rewrites `type`**, 0 ⇄ 5 — captured, and the
                    // only place in this client a channel's kind is mutable.
                    set: { overview.kind = $0 ? .announcement : .text }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private var hideAfterInactivity: some View {
        SheetField(
            title: "Hide After Inactivity",
            detail: isForum
                ? "New posts will not show in the channel list after being inactive for the "
                    + "specified duration."
                : "New threads will not show in the channel list after being inactive for the "
                    + "specified duration."
        ) {
            FlyoutPicker(
                selection: Binding(
                    // Discord's own default where a channel was never given one.
                    get: { overview.autoArchiveMinutes ?? 4320 },
                    set: { overview.autoArchiveMinutes = $0 }
                ),
                options: ThreadArchiveDuration.minutes,
                title: ThreadArchiveDuration.title,
                accessibilityTitle: "Hide After Inactivity"
            )
        }
    }

    /// One switch over one flag bit, the rest of the field untouched.
    ///
    /// `isOnWhenSet` is false for Discord's two inverted bits — the switch says
    /// "show" and the bit says "hide".
    private func flagToggle(
        _ title: String,
        detail: String?,
        flag: ChannelFlags,
        isOnWhenSet: Bool
    ) -> some View {
        SheetField(title: title, detail: detail) {
            Toggle(
                title,
                isOn: Binding(
                    get: { (overview.flags & flag.rawValue != 0) == isOnWhenSet },
                    set: { isOn in
                        let setsBit = isOn == isOnWhenSet
                        overview.flags = setsBit
                            ? overview.flags | flag.rawValue
                            : overview.flags & ~flag.rawValue
                    }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    // MARK: Voice

    private var bitrate: some View {
        SheetField(title: "Bitrate") {
            FlyoutPicker(
                selection: $overview.bitrate,
                options: BoostTier.bitrateChoices(maximum: maximumBitrate, current: overview.bitrate),
                title: { "\($0 / 1000)kbps" },
                accessibilityTitle: "Bitrate"
            )
        }
    }

    private var videoQuality: some View {
        SheetField(title: "Video Quality") {
            FlyoutPicker(
                selection: Binding(
                    get: { overview.videoQualityMode ?? VideoQualityMode.automatic },
                    set: { overview.videoQualityMode = $0 }
                ),
                options: [VideoQualityMode.automatic, VideoQualityMode.full],
                title: VideoQualityMode.title,
                accessibilityTitle: "Video Quality"
            )
        }
    }

    private var userLimit: some View {
        SheetField(title: "User Limit") {
            HStack(spacing: Spacing.snug) {
                Slider(
                    value: Binding(
                        get: { Double(overview.userLimit) },
                        set: { overview.userLimit = Int($0.rounded()) }
                    ),
                    in: 0...99,
                    step: 1
                )
                .controlSize(.small)
                .accessibilityLabel(Text("User Limit"))
                .accessibilityValue(Text(userLimitTitle))
                Text(userLimitTitle)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
    }

    private var userLimitTitle: String {
        overview.userLimit == 0 ? "No Limit" : "\(overview.userLimit) users"
    }

    private var regionOverride: some View {
        SheetField(
            title: "Region Override",
            detail: "Anyone in this channel will attempt to connect to the region you set, "
                + "regardless of where they live. Regions affect voice and video quality. Leave it "
                + "on Automatic and Discord will figure out what works best."
        ) {
            FlyoutPicker(
                selection: $overview.rtcRegion,
                options: [nil] + regions.map { Optional($0.id) },
                title: { id in
                    guard let id else { return "Automatic" }
                    return regions.first { $0.id == id }?.name ?? id
                },
                accessibilityTitle: "Region Override"
            )
        }
    }
}
