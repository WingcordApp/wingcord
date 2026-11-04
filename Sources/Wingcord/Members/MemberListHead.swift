import SwiftUI
import WingcordCore

/// The head of the People tab, under the strip: what Discord's friends sidebar has
/// across its top (`nF`, `763349`) — the name, which organizes the list; search; add
/// friend; hide.
///
/// **The window header's idiom, one size down the column**: a glass capsule that
/// opens a menu, and a glass group of icons. Discord draws these bare; here they
/// float over the rows scrolling under them, as the strip above them does.
struct MemberListHead: View {
    /// What's being searched for, or nil while the row is the name and its buttons.
    @Binding var search: String?

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isAddFriendShown = false

    /// As tall as the strip above it and the search field that replaces it.
    static let height: CGFloat = SearchField.height

    var body: some View {
        Group {
            if let query = search {
                HStack(spacing: Spacing.base) {
                    SearchField(
                        prompt: "Search Members",
                        text: Binding(get: { query }, set: { search = $0 }),
                        takesFocus: true,
                        onCancel: close
                    )
                    HeaderCircleButton(systemImage: "xmark", label: "Close Search", action: close)
                }
                .transition(.materialize(from: .trailing, blurring: false))
            } else {
                HStack(spacing: Spacing.base) {
                    organize
                    Spacer(minLength: 0)
                    controls
                }
                .transition(.opacity)
            }
        }
        .frame(height: Self.height)
        .animation(motion.glassMorph, value: search == nil)
    }

    private func close() {
        search = nil
    }

    // MARK: Organize

    /// "Members ⌄": Discord's "Friends ⌄", and its menu — `nv`.
    private var organize: some View {
        Menu {
            MemberListOrganizeMenu(model: model)
        } label: {
            HStack(spacing: Spacing.tight) {
                Text("Members")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(InkColor.solid)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 14)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: ShellMetrics.headerControl)
        .contentShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Organize Members")
    }

    // MARK: Search, add friend, hide

    private var controls: some View {
        HeaderControlGroup {
            HeaderGroupButton(systemImage: "magnifyingglass", label: "Search Members") {
                search = ""
            }
            HeaderGroupButton(systemImage: "person.badge.plus", label: "Add Friend", isActive: isAddFriendShown) {
                isAddFriendShown.toggle()
            }
            .popover(isPresented: $isAddFriendShown, arrowEdge: .bottom) {
                AddFriendFlyout()
            }
            // The window header's toggle is the way back: this one goes away with
            // what it hides.
            HeaderGroupButton(systemImage: "sidebar.trailing", label: "Hide Members") {
                model.isMemberListShown = false
            }
        }
    }
}

/// Organize by: Discord's `nv`, as a native menu with a sentence under each choice.
private struct MemberListOrganizeMenu: View {
    var model: AppModel

    var body: some View {
        let capabilities = model.memberListCapabilities
        @Bindable var settings = AppSettings.shared
        Section("Organize by") {
            ForEach(MemberListOrganization.allCases) { option in
                if option != .roles || capabilities.hasRoles {
                    Toggle(isOn: Binding(
                        get: { capabilities.resolved(settings.memberListOrganization) == option },
                        set: { if $0 { settings.memberListOrganization = option } }
                    )) {
                        Text(option.title)
                        if let summary = option.summary { Text(summary) }
                    }
                    // Discord's letter sections need the whole list, and the
                    // server won't send a long one whole.
                    .disabled(option == .alphabetical && !capabilities.isWhole)
                }
            }
        }
        if capabilities.resolved(settings.memberListOrganization) != .alphabetical {
            Section("Advanced") {
                Toggle(isOn: $settings.groupsMembersInVoice) {
                    Text("Group Members in Voice")
                    Text("People in the same voice channel will be grouped together")
                }
            }
        }
    }
}
