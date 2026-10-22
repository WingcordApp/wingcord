import SwiftUI
import WingcordCore

// MARK: - A clip in the viewer
//
// docs/CLIPS-PRESENCE.md, D15 / D16 / Phase 4.5 — what Discord's player in
// chat draws over a clip (see `AppModel+ClipPlayer`): its title, game and
// people; who is speaking as it plays; its moments and its timeline comments
// on the scrubber; and a comment sent at the current moment. Not burnt into
// the picture: all of it comes from the clip's own fields.

/// The clip player's switches and the comment being written — the viewer's
/// own, for as long as it is up.
@Observable
final class ClipPlayerState {
    /// Discord's "Speaking indicators", on by default.
    var showsSpeaking = true
    /// Discord's "Timeline comments", on by default.
    var showsComments = true
    var draft = ""
    /// The comment field has the keyboard — the viewer's keys wait.
    var isCommenting = false
}

/// What the video bar adds for a clip.
struct ClipBarExtras {
    var marks: [ClipMark]
    var hasSpeaking: Bool
    var hasComments: Bool
    var state: ClipPlayerState
}

/// The clip's title, game and people, beside Close.
///
/// Discord's header (module 478531): the title or "Untitled", the game · when
/// it was made, and up to four faces with "N more participants".
struct ClipHeaderCard: View {
    var clip: AttachmentClip
    var faces: [ClipFace]

    private static let shownFaces = 4

    var body: some View {
        HStack(spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Label {
                    Text(title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                } icon: {
                    Image(symbol: "film")
                        .foregroundStyle(InkColor.primary)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Typeface.metadata)
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
            }
            if !faces.isEmpty {
                ClipFaceRow(faces: faces, shown: Self.shownFaces)
            }
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .rect(cornerRadius: Radius.glass, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        guard let title = clip.title, !title.isEmpty else { return "Untitled" }
        return title
    }

    private var subtitle: String? {
        let parts = [
            clip.applicationName,
            clip.createdAt.map { $0.formatted(.relative(presentation: .named)) },
        ].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Discord's "Alternate point of view" (Phase 7.3): the other views of this
/// moment — "Original", "Switch to *name*" — and "Add your POV" when the
/// reader has a clip of it they have not shared here.
struct ClipPOVSwitcher: View {
    var views: [ClipPointsOfView.View]
    var current: AttachmentID
    var name: (UserID) -> String
    var canAddMine: Bool
    var switchTo: (ClipPointsOfView.View) -> Void
    var addMine: () -> Void

    var body: some View {
        HStack(spacing: Spacing.tight) {
            if views.count > 1 {
                Menu {
                    Section("Alternate point of view") {
                        ForEach(views) { view in
                            Button(title(for: view)) { switchTo(view) }
                                .disabled(view.id == current)
                        }
                    }
                } label: {
                    Label(currentTitle, systemImage: "person.2.wave.2")
                        .font(.system(.caption, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
                .help("Alternate point of view")
            }
            if canAddMine {
                Button("Add your POV", systemImage: "plus", action: addMine)
                    .font(.system(.caption, weight: .semibold))
                    .buttonStyle(.glass)
            }
        }
        .controlSize(.small)
    }

    private func title(for view: ClipPointsOfView.View) -> String {
        view.isOriginal ? "Original — \(name(view.authorID))" : "Switch to \(name(view.authorID))"
    }

    private var currentTitle: String {
        guard let view = views.first(where: { $0.id == current }) else { return "Points of view" }
        return view.isOriginal ? "Original" : name(view.authorID)
    }
}

/// Up to `shown` faces, and the rest as a count.
private struct ClipFaceRow: View {
    var faces: [ClipFace]
    var shown: Int

    var body: some View {
        HStack(spacing: Spacing.tight) {
            ForEach(faces.prefix(shown)) { face in
                AvatarView(url: face.url, monogram: face.monogram, side: 24)
                    .help(face.name)
            }
            if faces.count > shown {
                let rest = faces.dropFirst(shown)
                Text("+\(rest.count)")
                    .font(.system(.caption, weight: .semibold).monospacedDigit())
                    .foregroundStyle(InkColor.primary)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(.white.opacity(0.12), in: .circle)
                    .help(rest.map(\.name).joined(separator: ", "))
                    // Discord's `CJ0I6C`.
                    .accessibilityLabel(rest.count == 1 ? "1 more participant" : "\(rest.count) more participants")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Participants")
    }
}

/// Who is speaking at this moment of the clip — Discord's speaking list
/// (module 773503): a face and a name each, while "Speaking indicators" is on.
struct ClipSpeakingList: View {
    var faces: [ClipFace]
    var speaking: Set<UInt64>

    @Environment(\.motion) private var motion

    var body: some View {
        let lit = faces.filter { speaking.contains($0.id.rawValue) }
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(lit) { face in
                HStack(spacing: Spacing.base) {
                    AvatarView(url: face.url, monogram: face.monogram, side: 24)
                        .overlay { Circle().strokeBorder(Palette.presenceOnline, lineWidth: 2) }
                    Text(face.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                }
                .padding(.leading, Spacing.tight)
                .padding(.trailing, Spacing.snug)
                .padding(.vertical, Spacing.tight)
                .glassEffect(.clear.tint(Palette.flyoutTint), in: .capsule)
                .transition(.opacity)
                .accessibilityLabel("\(face.name), speaking")
            }
        }
        .animation(motion.fadeQuick, value: lit.map(\.id))
    }
}

/// The marks over the scrubber, each where its moment falls on the slider's
/// track. Clicking one goes to it.
///
/// **Two lanes**, as Discord's player keeps them: the comments in their own
/// row above the game's moments, so a reply at a kill does not sit on the
/// kill's mark.
///
/// **Placed on the track, not on the slider's frame.** The knob's centre runs
/// half a knob in from each end (20 points wide at the regular size, measured
/// from `NSSliderCell.knobRect`), so a mark at the end of the clip sits where
/// the knob does when it gets there.
struct ClipMarkerRow: View {
    var marks: [ClipMark]
    /// The slider's frame, in the row's own space.
    var track: CGRect
    var duration: Double
    var currentTime: Double
    var seek: (Double) -> Void

    static let laneHeight: CGFloat = 22
    private static let knobInset: CGFloat = 10

    var body: some View {
        let comments = marks.filter { if case .comment = $0.kind { true } else { false } }
        let moments = marks.filter { if case .comment = $0.kind { false } else { true } }
        VStack(spacing: 0) {
            if !comments.isEmpty { lane(comments) }
            if !moments.isEmpty { lane(moments) }
        }
    }

    private func lane(_ marks: [ClipMark]) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(marks) { mark in
                ClipMarkButton(
                    mark: mark,
                    isPassed: currentTime >= mark.seconds,
                    isNear: abs(currentTime - mark.seconds) <= 1,
                    seek: seek
                )
                .position(x: x(mark.seconds), y: Self.laneHeight / 2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.laneHeight)
    }

    private func x(_ seconds: Double) -> CGFloat {
        let travel = max(0, track.width - Self.knobInset * 2)
        return track.minX + Self.knobInset + travel * CGFloat(min(1, max(0, seconds / max(duration, 0.01))))
    }
}

/// One mark. A comment that is one emoji is drawn as itself, as Discord draws
/// it, and grows while the playhead is within a second of it.
private struct ClipMarkButton: View {
    var mark: ClipMark
    var isPassed: Bool
    var isNear: Bool
    var seek: (Double) -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        Button { seek(mark.seconds) } label: {
            glyph
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(mark.title) — \(mark.detail)")
        .accessibilityLabel("\(mark.title), \(mediaTimeLabel(Int(mark.seconds)))")
        .animation(motion.standard, value: isNear)
    }

    @ViewBuilder
    private var glyph: some View {
        let side: CGFloat = isNear ? 20 : 13
        switch mark.kind {
        case .comment(let comment):
            Group {
                switch comment.emoji {
                case .unicode(let text):
                    Text(text).font(.system(size: side - 2))
                case .custom(_, let url):
                    RemoteImage(url: url, side: 20) { Color.clear }
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side, height: side)
                case nil:
                    Image(symbol: mark.symbolName)
                        .font(.system(size: side - 4))
                        .foregroundStyle(mark.tint)
                }
            }
            .opacity(isNear ? 1 : 0.55)
        default:
            Image(symbol: mark.symbolName)
                .font(.system(size: isNear ? 14 : 11, weight: .semibold))
                .foregroundStyle(mark.tint)
                .opacity(isPassed ? 1 : 0.6)
        }
    }
}

/// The comment at the playhead — its face, name and words — while it is
/// within a second of its moment: Discord's tooltip that opens by itself.
struct ClipCommentCaption: View {
    var comment: TimelineComment

    var body: some View {
        HStack(spacing: Spacing.base) {
            AvatarView(url: comment.avatarURL, monogram: comment.monogram, side: 20)
            Text(comment.authorName)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            Text(comment.content)
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.primary)
                .lineLimit(2)
        }
        .padding(.leading, Spacing.tight)
        .padding(.trailing, Spacing.snug)
        .padding(.vertical, Spacing.tight)
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .capsule)
        .opacity(comment.isPending ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// Discord's comment bar (module 560149's `ClipEmbedMediaMentionBar`): quick
/// emoji and a reply, both "To current time". The reply is written here, at
/// the clip, rather than in a composer the viewer covers — and the clip
/// pauses while it is, as Discord's Reply pauses it.
struct ClipCommentBar: View {
    @Bindable var state: ClipPlayerState
    var playback: VideoPlayback
    var send: (_ text: String, _ milliseconds: Int) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            ForEach(AppModel.clipQuickEmoji, id: \.self) { emoji in
                ClipEmojiControl(emoji: emoji) { send(emoji, moment) }
            }
            Divider().frame(height: 18).opacity(0.4)
            TextField("Comment at \(mediaTimeLabel(playback.elapsedSeconds))", text: $state.draft)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .foregroundStyle(InkColor.primary)
                .focused($isFocused)
                .onSubmit(submit)
                .onExitCommand {
                    state.draft = ""
                    isFocused = false
                }
                .frame(minWidth: 160)
            MediaBarControl(
                systemImage: "arrow.up",
                label: "Send",
                isActive: !trimmed.isEmpty,
                isEnabled: !trimmed.isEmpty,
                action: submit
            )
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.tight)
        .glassEffect(.clear.tint(Palette.flyoutTint), in: .capsule)
        .onChange(of: isFocused) { _, focused in
            state.isCommenting = focused
            if focused, playback.isPlaying { playback.togglePlayback() }
        }
    }

    private var trimmed: String { state.draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Discord's moment: the player's time in milliseconds, floored.
    private var moment: Int { Int((playback.currentTime * 1_000).rounded(.down)) }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        send(trimmed, moment)
        state.draft = ""
        isFocused = false
    }
}

/// A quick emoji in the comment bar — a region of the bar's material, as
/// `MediaBarControl` is.
private struct ClipEmojiControl: View {
    var emoji: String
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 16))
                .frame(width: Metrics.control, height: Metrics.control)
                .background { Circle().fill(.white.opacity(isHovering ? 0.16 : 0.08)) }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        // Discord's `wQFVGI`.
        .help("React with \(emoji) — To current time")
        .accessibilityLabel(Text("React with \(emoji) at the current time"))
    }
}

/// A clip on stage, gathered for one pass of the chrome: its people, its
/// timeline comments, and the send — nil where the reader cannot comment.
struct ClipInViewer {
    var clip: AttachmentClip
    var faces: [ClipFace]
    var comments: [TimelineComment] = []
    var send: ((_ text: String, _ milliseconds: Int) -> Void)?

    init(item: MediaItem, clip: AttachmentClip, request: MediaViewerRequest, model: AppModel) {
        self.clip = clip
        faces = model.clipFaces(clip, in: request.channelID)
        guard let channelID = request.channelID else { return }
        comments = model.timelineComments(on: item.id, in: channelID)
        if let messageID = request.messageID, model.canCommentOnClip(in: channelID) {
            let attachmentID = item.id
            send = { [weak model] text, milliseconds in
                model?.sendTimelineComment(text, at: milliseconds, on: attachmentID, of: messageID, in: channelID)
            }
        }
    }

    func moments(duration: Double) -> [ClipMark] {
        ClipMark.moments(in: clip.timeline, duration: duration)
    }
}

/// The speaking list, re-read as the clip plays — its own view, so the clock
/// re-evaluates this and nothing around it.
struct ClipSpeakingLayer: View {
    var clip: AttachmentClip
    var faces: [ClipFace]
    var playback: VideoPlayback

    var body: some View {
        ClipSpeakingList(faces: faces, speaking: clip.speakers(at: Int(playback.currentTime * 1_000)))
    }
}

/// The comment in words at the playhead, if there is one — its own view for
/// the same reason.
struct ClipCommentCaptionLayer: View {
    var comments: [TimelineComment]
    var playback: VideoPlayback

    @Environment(\.motion) private var motion

    var body: some View {
        let now = Int(playback.currentTime * 1_000)
        let near = comments.last { $0.emoji == nil && abs($0.timestampMS - now) <= 1_000 }
        ZStack {
            if let near {
                ClipCommentCaption(comment: near)
                    .id(near.id)
                    .transition(.opacity)
            }
        }
        .animation(motion.fade, value: near?.id)
    }
}
