import SwiftUI
import WingcordCore

/// "Add Connection" — the grid of services, raised from the profile.
///
/// **The same platforms and the same two calls the settings page already
/// makes.** `ConnectedAppsPane` has had this grid since connections shipped;
/// what was missing was a way to reach it from the profile, where the
/// Connections list actually lives. So this is the settings grid in a sheet, not
/// a second implementation of it — `ConnectionPlatform.addable` names the
/// services and `SessionController` opens the browser.
struct AddConnectionSheet: View {
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model

    private static let tile: CGFloat = 52

    /// Sorted by the name on the tile rather than the wire key, or "eBay" and
    /// "PlayStation" land wherever their lowercased first letter falls. The same
    /// ordering the settings grid uses, for the same reason.
    private var services: [String] {
        (ConnectionPlatform.addable + [ConnectionPlatform.domain]).sorted {
            (BrandMark.mark(for: $0)?.name ?? $0) < (BrandMark.mark(for: $1)?.name ?? $1)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: Self.tile, maximum: Self.tile),
                        spacing: Spacing.snug
                    )
                ],
                alignment: .leading,
                spacing: Spacing.snug
            ) {
                ForEach(services, id: \.self) { service in
                    tile(service)
                }
            }
            .padding(.horizontal, Spacing.group)
            .padding(.bottom, Spacing.group)
        }
        .frame(width: 520)
    }

    private var header: some View {
        ModalHeader(
            title: "Add Connection",
            subtitle: Text("Link an account to show it on your profile."),
            close: dismiss
        )
    }

    private func tile(_ service: String) -> some View {
        let name = service == ConnectionPlatform.domain
            ? "Domain"
            : (BrandMark.mark(for: service)?.name ?? service.capitalized)
        return Button {
            // **The sheet closes before the browser opens.** Linking leaves the
            // app entirely and comes back through a callback; a sheet still up
            // behind Safari is a sheet the reader has to dismiss to see the
            // connection they just made.
            dismiss()
            if service == ConnectionPlatform.domain {
                model.sessionController.beginDomainConnection()
            } else {
                model.sessionController.beginLinkingConnection(type: service)
            }
        } label: {
            ConnectionMark(service: service, side: Self.tile)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(Text("Add \(name)"))
    }
}
