import SwiftUI
import WingcordCore

/// Discord's Add Widget: the catalog, as tiles, each one added with a click.
struct AddWidgetSheet: View {
    var guildID: GuildID
    var column: Int
    var index: Int

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var entries: [GuildSpaceCatalogEntry]? {
        model.serverHub.catalogs[guildID].map {
            GuildSpaceCatalogEntry.addable($0, given: model.serverHub.draft?.widgets ?? [])
                .filter(\.kind.isDrawn)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Add Widget")
                    .font(.system(.title2, weight: .bold))
                Text("Pick a widget to add to your Server Hub. You can drag it anywhere afterwards.")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
            }
            Group {
                if let entries {
                    if entries.isEmpty {
                        ContentUnavailableView(
                            "Every widget is on your hub",
                            systemImage: "checkmark.circle",
                            description: Text("Remove one to add another of its kind.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.margin)], spacing: Spacing.margin) {
                            ForEach(entries) { entry in
                                AddWidgetTile(entry: entry) { add(entry) }
                            }
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Spacing.group)
        .frame(width: 560)
        .task { model.sessionController.loadServerHubCatalog(guildID) }
    }

    private func add(_ entry: GuildSpaceCatalogEntry) {
        model.addServerHubWidget(entry, column: column, index: index)
        // An Image + Text opens straight onto its words (`addServerHubWidget`);
        // anything else simply closes.
        if entry.kind != .imageText { dismiss() }
    }

    private func cancel() {
        dismiss()
    }
}
