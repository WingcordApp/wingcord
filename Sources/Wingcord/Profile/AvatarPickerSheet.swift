import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore
import WingcordNet

/// "Select an Image" — the avatar picker.
///
/// **Three ways to arrive at a picture, and they are three different requests.**
/// Bytes are an upload, one of the recents is `avatar_id` and costs no upload at
/// all, and taking the avatar off is an explicit `null`. That is why
/// `ProfileEditor.AvatarEdit` has four cases rather than being an `ImageData?` —
/// see its own note.
///
/// **Nothing here writes.** Every choice lands in the draft and the save bar
/// commits, which is what lets the reader try three avatars and take all of it
/// back with Reset.
struct AvatarPickerSheet: View {
    var profile: ProfilePresentation
    var current: ProfileEditor.AvatarEdit
    var choose: (ProfileEditor.AvatarEdit) -> Void
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model
    @State private var recents: [RecentAvatar] = []
    @State private var isLoading = true
    @State private var failure: String?

    /// Discord's own copy says six, and the captured list came back with four —
    /// so the number is a ceiling, not a promise, and the grid draws what
    /// arrived rather than padding to six empty circles.
    private static let side: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.railHairline)
            VStack(alignment: .leading, spacing: Spacing.group) {
                sources
                recentsSection
            }
            .padding(Spacing.group)
        }
        .frame(width: 460)
        .background(Palette.surface)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Text("Select an Image")
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(InkColor.primary)
            Spacer(minLength: Spacing.margin)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(InkColor.secondary)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.margin)
    }

    // MARK: Where a picture comes from

    private var sources: some View {
        HStack(spacing: Spacing.snug) {
            sourceTile(title: "Upload Image", symbol: "photo.badge.plus", action: upload)
            // **Removal is a source, not a footnote.** Discord buries it in the
            // avatar's own context menu; here it sits beside the other two
            // because it is the same decision — what the picture is going to be
            // — and it is the one people look for.
            sourceTile(title: "Remove Avatar", symbol: "person.crop.circle.badge.xmark") {
                choose(.removed)
            }
        }
    }

    private func sourceTile(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: Spacing.base) {
                Image(symbol: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(InkColor.secondary)
                Text(title)
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .background {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(Palette.skeletonPlate)
            }
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Reads a file the reader picked and hands its bytes to the draft.
    ///
    /// **The bytes are sent as they are, not re-encoded.** Discord takes the
    /// original and does its own resizing; a client that re-compressed first
    /// would upload a worse picture than the one chosen, and an animated GIF
    /// would stop moving.
    private func upload() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bytes = try? Data(contentsOf: url)
        else { return }
        let type = UTType(filenameExtension: url.pathExtension)
        choose(.uploaded(ImageData(mimeType: type?.preferredMIMEType ?? "image/png", bytes: bytes)))
    }

    // MARK: The recents

    @ViewBuilder
    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("Recent Avatars")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            Text("The avatars Discord still holds for you.")
                .font(Typeface.rowSubtitle)
                .foregroundStyle(InkColor.tertiary)

            if isLoading {
                ProgressView().controlSize(.small).padding(.vertical, Spacing.snug)
            } else if let failure {
                Text(failure)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.secondary)
            } else if recents.isEmpty {
                Text("Discord isn't holding any previous avatars for you.")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.tertiary)
            } else {
                HStack(spacing: Spacing.snug) {
                    ForEach(recents) { avatar in
                        recentTile(avatar)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func recentTile(_ avatar: RecentAvatar) -> some View {
        Button { choose(.recent(avatar)) } label: {
            RemoteImage(
                url: CDN.avatar(
                    userID: profile.userID,
                    hash: avatar.storageHash,
                    side: Self.side
                ),
                side: Self.side,
                bucket: .thumbnail
            ) {
                Circle().fill(Palette.skeletonPlate)
            }
            .aspectRatio(contentMode: .fill)
            .frame(width: Self.side, height: Self.side)
            .clipShape(.circle)
            .overlay {
                Circle().strokeBorder(
                    isChosen(avatar) ? Color.accentColor : .clear,
                    lineWidth: 2
                )
            }
        }
        .buttonStyle(.plain)
        // Discord composes this from the original file name and the upload date,
        // and it is often absent — so the fallback is the only description a
        // reader who cannot see it would otherwise get.
        .accessibilityLabel(Text(avatar.description ?? "A previous avatar"))
        .help(avatar.description ?? "")
    }

    private func isChosen(_ avatar: RecentAvatar) -> Bool {
        if case .recent(let chosen) = current { chosen.id == avatar.id } else { false }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            recents = try await model.sessionController.rest.recentAvatars()
        } catch {
            failure = "Couldn't load your recent avatars. \(error.localizedDescription)"
        }
    }
}
