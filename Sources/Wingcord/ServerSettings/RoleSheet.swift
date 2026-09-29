import SwiftUI
import WingcordCore

// MARK: - Editing a role
//
// Two tabs, because the two halves are genuinely different work: Display is five
// controls, Permissions is fifty-odd switches with a search field over them.
//
// **The whole role goes back on save.** Every captured `PATCH /roles/{id}` sends
// name, permissions, colour, both colour shapes, hoist, mentionable, icon and
// unicode emoji — so the sheet edits a copy of the `Role` and hands the copy
// over, and there is no arrangement of controls that can send a subset.
//
// The bit that is easy to get wrong and expensive when you do: **a permission
// this client does not know about must survive the round trip.** The editor
// draws `PermissionCatalog.known`; the save re-adds `unknownBits`, or every role
// edited here would silently lose whatever Discord shipped last month.

struct RoleSheet: View {
    var role: Role
    var guildID: GuildID
    /// Whether the server has `ENHANCED_ROLE_COLORS`, which is what offers
    /// the Gradient and Holographic styles at all.
    var allowsStyles = false
    var commit: (Role) -> Void

    @State private var draft: Role
    @State private var tab: Tab = .display
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case display = "Display"
        case permissions = "Permissions"
        var id: Self { self }
    }

    init(role: Role, guildID: GuildID, allowsStyles: Bool = false, commit: @escaping (Role) -> Void) {
        self.role = role
        self.guildID = guildID
        self.allowsStyles = allowsStyles
        self.commit = commit
        _draft = State(initialValue: role)
    }

    private var isEveryone: Bool { role.isEveryone(in: guildID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Spacing.margin)
            .padding(.bottom, Spacing.snug)

            ScrollView {
                switch tab {
                case .display: display
                case .permissions: permissions
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider()
            footer
        }
        .frame(width: 520, height: 620)
        .background(Palette.surface)
    }

    private var header: some View {
        HStack(spacing: Spacing.base) {
            RoleSwatch(role: draft)
            Text(isEveryone ? "Default permissions" : "Edit role — \(draft.name)")
                .font(.system(.headline))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.margin)
        .padding(.bottom, Spacing.snug)
    }

    // MARK: Display

    @ViewBuilder
    private var display: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if isEveryone {
                // @everyone has no name, no colour and no hoist — Discord
                // refuses all three. A tab of dimmed controls says less than one
                // sentence does. §5.5.
                Text(
                    "@everyone applies to every member. It cannot be renamed, "
                        + "coloured, or shown separately in the member list."
                )
                .font(SettingsType.rowLabel)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                SheetField(title: "Name", isRequired: true) {
                    TextField("new role", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }

                SheetField(
                    title: "Colour",
                    detail: "Members take the colour of the highest role they hold that has one."
                ) {
                    HStack(spacing: Spacing.snug) {
                        ColorPicker(
                            "",
                            selection: Binding(
                                get: { Color(hex: draft.colorValue) },
                                set: { colour in
                                    let value = colour.rgbValue
                                    draft.colorValue = value
                                    // Both, always — see the capture. A role
                                    // whose `colors` disagreed with its `color`
                                    // would render differently in two clients.
                                    draft.colors = RoleColors(
                                        primary: value,
                                        secondary: draft.colors?.secondary,
                                        tertiary: draft.colors?.tertiary
                                    )
                                }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()

                        Button("No colour") {
                            draft.colorValue = 0
                            draft.colors = RoleColors(primary: 0)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(draft.colorValue == 0)

                        Spacer()
                    }
                    .disabled(style == .holographic)
                }

                // **Discord's three styles**, offered where the server has
                // bought them. A role styled elsewhere still shows its style
                // here, and keeps it through a save rather than being
                // flattened, even where the picker cannot be used.
                if allowsStyles || style != .solid {
                    SheetField(title: "Style", detail: styleDetail) {
                        VStack(alignment: .leading, spacing: Spacing.snug) {
                            SegmentedPicker(
                                options: [
                                    .init(RoleColors.Style.solid, "Solid"),
                                    .init(.gradient, "Gradient"),
                                    .init(.holographic, "Holographic"),
                                ],
                                selection: Binding(get: { style }, set: setStyle)
                            )
                            .disabled(!allowsStyles)
                            HStack(spacing: Spacing.snug) {
                                if style == .gradient {
                                    ColorPicker(
                                        "",
                                        selection: Binding(
                                            get: { Color(hex: draft.colors?.secondary ?? draft.colorValue) },
                                            set: { colour in
                                                draft.colors = RoleColors(
                                                    primary: draft.colorValue, secondary: colour.rgbValue
                                                )
                                            }
                                        ),
                                        supportsOpacity: false
                                    )
                                    .labelsHidden()
                                    .disabled(!allowsStyles)
                                }
                                RoleSwatch(role: draft)
                            }
                        }
                    }
                }

                SheetField(title: "Display") {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        Toggle(
                            "Show members with this role separately",
                            isOn: $draft.isHoisted
                        )
                        Toggle(
                            "Allow anyone to @mention this role",
                            isOn: $draft.isMentionable
                        )
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.margin)
    }

    // MARK: Style

    private var style: RoleColors.Style { draft.colors?.style ?? .solid }

    private var styleDetail: String {
        switch style {
        case .solid: "One colour."
        case .gradient: "Two colours, the first above and the second here."
        case .holographic: "The ‘Holographic’ role style doesn’t require you to select any colours."
        }
    }

    /// Discord's editor: Holographic's colours are fixed, a role becoming a
    /// gradient starts from Discord's own pair unless it already was one, and
    /// Solid keeps the first colour. The legacy `color` follows the first, as
    /// every captured save sends both.
    private func setStyle(_ next: RoleColors.Style) {
        guard next != style else { return }
        let colors: RoleColors = switch next {
        case .solid: RoleColors(primary: draft.colorValue)
        case .gradient: RoleColors.defaultGradient
        case .holographic: RoleColors.holographic
        }
        draft.colors = colors
        draft.colorValue = colors.primary
    }

    // MARK: Permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                TextField("Search permissions", text: $query)
                    .textFieldStyle(.plain)
                Spacer()
                if !draft.permissions.isEmpty {
                    Button("Clear permissions") {
                        // Unknown bits go too. "Clear" that left invisible bits
                        // set would be a button that does not do what it says.
                        draft.permissions = []
                    }
                    .buttonStyle(.plain)
                    .font(.system(.caption))
                    .foregroundStyle(Palette.accent)
                }
            }
            .padding(Spacing.base)
            .background(SettingsSurface.controlTrough, in: .settingsRect(8))
            .padding(.horizontal, Spacing.margin)
            .padding(.bottom, Spacing.snug)

            ForEach(PermissionCatalog.groups(matching: query)) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.title)
                        .font(SettingsType.sectionHeader)
                        .foregroundStyle(Ink.primary)
                        .padding(.top, Spacing.snug)
                        .padding(.bottom, Spacing.base)
                    ForEach(group.entries) { entry in
                        PermissionToggle(
                            entry: entry,
                            isOn: Binding(
                                get: { draft.permissions.contains(entry.permission) },
                                set: { isOn in
                                    if isOn { draft.permissions.insert(entry.permission) }
                                    else { draft.permissions.remove(entry.permission) }
                                }
                            )
                        )
                    }
                }
                .padding(.horizontal, Spacing.margin)
            }

            unknownNotice
        }
        .padding(.bottom, Spacing.margin)
    }

    /// What this client cannot draw, said out loud.
    ///
    /// A role holding a permission newer than this build would otherwise show a
    /// complete-looking list that is quietly missing one — and the reader would
    /// have no way to know the save was preserving something. Saying so is the
    /// difference between "kept" and "hidden".
    @ViewBuilder
    private var unknownNotice: some View {
        let unknown = PermissionCatalog.unknownBits(in: role.permissions)
        if !unknown.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                Image(systemName: "info.circle")
                    .foregroundStyle(Ink.tertiary)
                Text(
                    "This role also holds permissions this version of Wingcord "
                        + "does not know about. They are kept exactly as they are."
                )
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.top, Spacing.snug)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Spacing.base) {
            if draft.permissions.contains(.administrator) {
                Label(
                    "Administrator grants everything.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(.caption))
                .foregroundStyle(.orange)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                var next = draft
                // The bits the catalog cannot draw, put back. Without this line
                // every role edited here loses whatever Discord added since this
                // build shipped.
                next.permissions.formUnion(PermissionCatalog.unknownBits(in: role.permissions))
                commit(next)
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!isDirty || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(Spacing.margin)
    }

    private var isDirty: Bool {
        draft.name != role.name
            || draft.colorValue != role.colorValue
            || draft.colors != role.colors
            || draft.isHoisted != role.isHoisted
            || draft.isMentionable != role.isMentionable
            || draft.permissions != role.permissions
    }
}

/// One permission, with its sentence.
private struct PermissionToggle: View {
    var entry: PermissionCatalog.Entry
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.tight) {
                    Text(entry.title)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Ink.primary)
                    if entry.isElevated {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("This grants more than it says.")
                    }
                }
                Text(entry.detail)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.snug)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(SettingsSurface.switchOn)
        }
        .padding(.vertical, Spacing.base)
        .overlay(alignment: .bottom) { CardDivider(leading: 0) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Colour

extension Color {
    /// Discord's 24-bit integer for this colour.
    ///
    /// Through `NSColor` in sRGB, because a `Color` built from an accent or a
    /// system colour has no components until it is resolved into a colour space
    /// — and the one Discord means is sRGB.
    var rgbValue: UInt32 {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return 0 }
        let red = UInt32((srgb.redComponent * 255).rounded())
        let green = UInt32((srgb.greenComponent * 255).rounded())
        let blue = UInt32((srgb.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }
}
