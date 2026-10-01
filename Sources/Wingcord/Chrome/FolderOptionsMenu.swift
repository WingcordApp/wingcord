import SwiftUI
import WingcordCore

/// What a folder offers, from a right-click on its tile in the rail — Discord's
/// folder menu (`842112`): Mark Folder As Read, Folder Settings and Close All
/// Folders.
///
/// **Folder Settings is a page of this flyout rather than Discord's modal**, as
/// the server menu's sheets are pages of it: a name and a colour are a line and
/// a row of swatches, and a window for them is a window for a word.
///
/// No material of its own: the popover's glass is the body — §4.9.
struct FolderOptionsMenu: View {
    var folderID: UInt64
    var close: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var surface: Surface = .root
    @State private var name = ""
    /// Nil is the default colour — see `RailFolder.defaultColor`.
    @State private var colorValue: UInt32?
    @FocusState private var isNameFocused: Bool

    enum Surface: Hashable {
        case root
        case settings
    }

    static let width: CGFloat = 272
    /// Discord's limit on a folder's name (`F05`).
    private static let nameLimit = 32

    var body: some View {
        let options = model.folderOptions(for: folderID)
        VStack(alignment: .leading, spacing: 0) {
            if let options {
                switch surface {
                case .root: rootMenu(options)
                case .settings: settingsPage
                }
            } else {
                FlyoutEmpty(text: "This folder is gone.")
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: Self.width)
        .animation(motion.standard, value: surface)
    }

    @ViewBuilder
    private func rootMenu(_ options: FolderOptions) -> some View {
        FlyoutRow(
            title: "Mark Folder As Read",
            symbolName: "envelope.open",
            isEnabled: options.hasUnread
        ) {
            model.markFolderRead(folderID)
            close()
        }
        FlyoutDivider()
        FlyoutRow(title: "Folder Settings", symbolName: "folder.badge.gearshape", accessory: .disclosure) {
            name = options.name ?? ""
            colorValue = options.colorValue
            surface = .settings
        }
        if options.hasOpenFolders {
            FlyoutRow(title: "Close All Folders", symbolName: "folder") {
                model.closeAllFolders()
                close()
            }
        }
    }

    @ViewBuilder
    private var settingsPage: some View {
        FlyoutBackRow(title: "Folder Settings") { surface = .root }
        FlyoutDivider()
        FlyoutSectionHeader(title: "Folder Name")
        TextField("Server Folder", text: $name)
            .textFieldStyle(.plain)
            .font(.system(.subheadline))
            .foregroundStyle(Ink.primary)
            .focused($isNameFocused)
            .onSubmit(save)
            .onChange(of: name) { _, value in
                guard value.count > Self.nameLimit else { return }
                name = String(value.prefix(Self.nameLimit))
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(Palette.hoverFill)
            }
            .padding(.horizontal, Spacing.snug)
            .task { isNameFocused = true }
        FlyoutSectionHeader(title: "Folder Color")
        FolderColorSwatches(selection: $colorValue)
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.base)
        FlyoutDivider()
        FlyoutRow(title: "Done", symbolName: "checkmark", act: save)
    }

    private func save() {
        model.saveFolderSettings(folderID, name: name, colorValue: colorValue)
        close()
    }
}

/// Discord's folder colours: the default, a colour of the reader's own, and
/// its twenty presets — the same twenty its role editor offers (`r_`).
private struct FolderColorSwatches: View {
    @Binding var selection: UInt32?

    private static let presets: [UInt32] = [
        0x1ABC9C, 0x2ECC71, 0x3498DB, 0x9B59B6, 0xE91E63,
        0xF1C40F, 0xE67E22, 0xE74C3C, 0x95A5A6, 0x607D8B,
        0x11806A, 0x1F8B4C, 0x206694, 0x71368A, 0xAD1457,
        0xC27C0E, 0xA84300, 0x992D22, 0x979C9F, 0x546E7A,
    ]
    private static let side: CGFloat = 20
    private static let spacing: CGFloat = 4

    /// What the selection is drawn as: the default where there is none.
    private var current: UInt32 { selection ?? RailFolder.defaultColor }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                swatch(RailFolder.defaultColor, side: 32, label: "Default")
                custom
                Spacer(minLength: 0)
            }
            row(Array(Self.presets.prefix(10)))
            row(Array(Self.presets.suffix(10)))
        }
    }

    private func row(_ colors: [UInt32]) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(colors, id: \.self) { color in
                swatch(color, side: Self.side, label: nil)
            }
        }
    }

    private func swatch(_ color: UInt32, side: CGFloat, label: String?) -> some View {
        let isChosen = current == color
        return Button {
            selection = color == RailFolder.defaultColor ? nil : color
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(hex: color))
                .frame(width: side, height: side)
                .overlay {
                    if isChosen {
                        Image(systemName: "checkmark")
                            .font(.system(size: side * 0.45, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label ?? String(format: "#%06X", color)))
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    /// A colour of the reader's own, through the system's picker — where
    /// Discord puts its own picker beside the default.
    private var custom: some View {
        ColorPicker(
            "Custom Color",
            selection: Binding(
                get: { Color(hex: current) },
                set: { selection = $0.rgbValue }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .help("Custom Color")
    }
}
