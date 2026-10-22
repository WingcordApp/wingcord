import SwiftUI
import WingcordCore

// MARK: - Editing the clips on a board
//
// docs/CLIPS-PRESENCE.md, Phase 7 (D18). Discord's clips gallery editor
// (`735321` in build 643186): up to four clips, each with a title, reordered
// and removed; a clip is added from the reader's own library. **Picked clips
// stay on this Mac until Save** — `ProfileEditor` uploads them there through
// Discord's clip route, as it does a personal widget's pictures, so a clip
// somebody thought better of never reaches Discord.

struct ClipsGalleryEditor: View {
    var clips: [ProfileClip]
    var update: ([ProfileClip]) -> Void

    @State private var isPicking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                ClipEditRow(
                    clip: clip,
                    canMoveUp: index > 0,
                    canMoveDown: index < clips.count - 1,
                    rename: { rename(clip.id, to: $0) },
                    move: { move(index, by: $0) },
                    remove: { update(clips.filter { $0.id != clip.id }) }
                )
            }
            if clips.count < ProfileClip.limit {
                Button {
                    isPicking = true
                } label: {
                    Label("Add a Clip", systemImage: "plus")
                        .font(.system(.subheadline, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                    LibraryClipPicker(taken: Set(clips.compactMap(\.localClipID))) { picked in
                        isPicking = false
                        add(picked)
                    }
                }
            }
            Text(footnote)
                .font(.system(.caption))
                .foregroundStyle(InkColor.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: String {
        let waiting = clips.filter { $0.localFile != nil }.count
        let limit = "Up to \(ProfileClip.limit) clips."
        guard waiting > 0 else { return limit }
        return limit + (waiting == 1 ? " One uploads" : " \(waiting) upload") + " when you save."
    }

    private func add(_ clip: Clip) {
        guard clips.count < ProfileClip.limit else { return }
        let manifest = clip.manifest
        update(clips + [
            ProfileClip(
                storage: .local(fileURL: clip.url),
                gameID: manifest?.game?.applicationID.map(ApplicationID.init(rawValue:)),
                title: manifest?.title ?? manifest?.game?.name,
                localClipID: manifest?.id.uuidString ?? clip.url.lastPathComponent
            ),
        ])
    }

    private func rename(_ id: String, to title: String) {
        update(clips.map { clip in
            guard clip.id == id else { return clip }
            var renamed = clip
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            renamed.title = trimmed.isEmpty ? nil : String(title.prefix(100))
            return renamed
        })
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard clips.indices.contains(index), clips.indices.contains(target) else { return }
        var reordered = clips
        reordered.swapAt(index, target)
        update(reordered)
    }
}

/// One clip in the editor: its picture, its title, and its order.
private struct ClipEditRow: View {
    var clip: ProfileClip
    var canMoveUp: Bool
    var canMoveDown: Bool
    var rename: (String) -> Void
    var move: (Int) -> Void
    var remove: () -> Void

    @State private var title = ""
    @State private var picture: CGImage?

    var body: some View {
        HStack(spacing: Spacing.snug) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                TextField("Add a title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, weight: .medium))
                    .onSubmit { rename(title) }
                    .onChange(of: title) { _, value in rename(value) }
                Text(clip.localFile != nil ? "Uploads when you save" : "On your profile")
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.tertiary)
            }
            Spacer(minLength: 0)
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                .accessibilityLabel("Move up")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                .accessibilityLabel("Move down")
            Button(action: remove) {
                Image(systemName: "trash")
                    .foregroundStyle(Palette.destructive)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove clip")
        }
        .onAppear { title = clip.title ?? "" }
        .task(id: clip.id) {
            if let file = clip.localFile {
                picture = await ClipThumbnails.shared.thumbnail(for: file, kind: .clip)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Palette.skeletonPlate)
            if let picture {
                Image(decorative: picture, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let url = clip.thumbnailURL {
                RemoteImage(url: url, side: 160, bucket: .thumbnail) { Color.clear }
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(.rect(cornerRadius: 8, style: .continuous))
    }
}

/// The reader's own clips, to choose one from — clips only: a screenshot is
/// not a video and a recording is not a clip.
private struct LibraryClipPicker: View {
    /// Library clips already on the board, by their local id.
    var taken: Set<String>
    var pick: (Clip) -> Void

    @State private var clips: [Clip] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if clips.isEmpty {
                    Text("You haven’t clipped anything yet.")
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                        .padding(Spacing.margin)
                }
                ForEach(clips) { clip in
                    Button { pick(clip) } label: {
                        PickerRow(clip: clip)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, Spacing.base)
        }
        .frame(width: 320, height: 300)
        .task {
            clips = ClipLibrary.contents().filter { clip in
                !clip.isScreenshot && !clip.isRecording
                    && !taken.contains(clip.manifest?.id.uuidString ?? clip.url.lastPathComponent)
            }
        }
    }
}

private struct PickerRow: View {
    var clip: Clip
    @State private var picture: CGImage?

    var body: some View {
        HStack(spacing: Spacing.snug) {
            ZStack {
                Rectangle().fill(Palette.skeletonPlate)
                if let picture {
                    Image(decorative: picture, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.manifest?.title ?? clip.name)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                Text(clip.created.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(.caption))
                    .foregroundStyle(InkColor.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.tight)
        .contentShape(.rect)
        .task(id: clip.url) {
            picture = await ClipThumbnails.shared.thumbnail(for: clip.url, kind: .clip)
        }
    }
}
