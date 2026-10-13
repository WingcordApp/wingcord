import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The picture card
//
// Choosing a picture, and the two things worth doing to one afterwards.
//
// **Blur and dim are the whole vocabulary, and neither is decoration.** A
// photograph behind a transcript is a legibility problem before it is a taste
// one: detail competes with glyphs and bright regions swallow secondary text.
// Blurring removes the detail and dimming removes the brightness, which are the
// two axes that actually decide whether the window is readable. There is no
// position control, no scaling mode and no opacity-per-column, because none of
// those change that answer and each is another thing to get wrong.

struct BackdropCard: View {
    @State private var theme = ThemeStore.shared
    @State private var renderer = BackdropRenderer.shared
    @State private var failure: String?
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                BackdropChooserRow(
                    picture: renderer.image,
                    hasBackdrop: theme.backdrop != nil,
                    choose: choose,
                    remove: { theme.setBackdrop(nil) }
                )
                if let backdrop = theme.backdrop {
                    CardDivider()
                    SettingsSliderRow(
                        title: "Blur",
                        help: "Softens the picture so its detail stops competing with the text on top of it.",
                        value: blurBinding(backdrop),
                        range: 0...1,
                        step: 0.02,
                        format: { $0.formatted(.percent.precision(.fractionLength(0))) }
                    )
                    CardDivider()
                    SettingsSliderRow(
                        title: "Depth",
                        help: "How far the theme's ground is drawn back over the picture. "
                            + "The transcript keeps a floor of it whatever this says.",
                        value: dimBinding(backdrop),
                        range: 0...1,
                        step: 0.02,
                        format: { $0.formatted(.percent.precision(.fractionLength(0))) }
                    )
                }
            }
            if let failure {
                SettingsFootnote(failure, symbolName: "exclamationmark.triangle")
            } else {
                SettingsFootnote(
                    "The picture fills the whole window, so one photograph runs behind the "
                        + "sidebar and the transcript without a seam between them. The sidebar "
                        + "shows more of it than the transcript does — nothing there is read for "
                        + "minutes at a time, and a message is.",
                    symbolName: "photo.on.rectangle.angled"
                )
            }
        }
        .animation(motion.standard, value: theme.backdrop == nil)
        .animation(motion.fade, value: failure)
    }

    // MARK: Bindings
    //
    // A binding straight through to the store rather than `@State` mirrored
    // back: the slider's value IS the setting, and a local copy would be a
    // second source of truth that has to be reconciled every time the theme is
    // set from anywhere else.

    private func blurBinding(_ backdrop: Backdrop) -> Binding<Double> {
        Binding(
            get: { backdrop.blur },
            set: { theme.setBackdrop(Backdrop(fileName: backdrop.fileName, blur: $0, dim: backdrop.dim)) }
        )
    }

    private func dimBinding(_ backdrop: Backdrop) -> Binding<Double> {
        Binding(
            get: { backdrop.dim },
            set: { theme.setBackdrop(Backdrop(fileName: backdrop.fileName, blur: backdrop.blur, dim: $0)) }
        )
    }

    // MARK: Choosing

    private func choose() {
        Task {
            guard let source = await Self.askForPicture() else { return }
            do {
                // Copied, never referenced — see `BackdropLibrary.adopt`. The
                // previous copy is discarded by the store, which is the only
                // thing that knows whether anything still points at it.
                let name = try BackdropLibrary.adopt(source)
                let existing = theme.backdrop
                theme.setBackdrop(Backdrop(
                    fileName: name,
                    blur: existing?.blur ?? 0.35,
                    dim: existing?.dim ?? 0.55
                ))
                failure = nil
            } catch {
                // Said in words rather than swallowed: a Choose button that
                // visibly does nothing is the shape of a broken feature, and the
                // realistic causes here — an unreadable volume, a file that
                // moved between the panel and the copy — are ones the reader can
                // act on.
                failure = "Couldn’t copy that picture into Wingcord’s own folder."
            }
        }
    }

    @MainActor
    private static func askForPicture() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = BackdropLibrary.readableTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use Picture"
        panel.message = "Choose a picture to fill the window behind Wingcord."
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return panel.runModal() == .OK ? panel.url : nil
        }
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }
}

// MARK: - The row that has the picture in it

private struct BackdropChooserRow: View {
    var picture: CGImage?
    var hasBackdrop: Bool
    var choose: () -> Void
    var remove: () -> Void

    private static let thumbnailWidth: CGFloat = 84
    private static let thumbnailHeight: CGFloat = 50

    var body: some View {
        HStack(spacing: Spacing.snug) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text("Picture")
                    .font(SettingsType.rowTitle)
                    .foregroundStyle(Ink.primary)
                Text(hasBackdrop
                    ? "Filling the window behind the theme."
                    : "None. The theme’s own ground is showing.")
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.base)
            if hasBackdrop {
                Button("Remove", role: .destructive, action: remove)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(hasBackdrop ? "Replace…" : "Choose…", action: choose)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.leading, SettingsMetrics.cardContentInset)
        .padding(.trailing, SettingsMetrics.controlTrailing)
        .padding(.vertical, SettingsMetrics.cardContentInset)
        .frame(maxWidth: .infinity)
    }

    /// The rendered bitmap, not a fresh decode of the file.
    ///
    /// It is the *same* picture the window is drawing, at the same blur — which
    /// makes this a preview of the setting rather than a preview of the file,
    /// and costs nothing: the bitmap is already resident.
    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(SettingsSurface.controlTrough)
            .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
            .overlay {
                if let picture {
                    Image(decorative: picture, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
                        .clipShape(.rect(cornerRadius: 7, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 15))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(SettingsSurface.hairline, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}
