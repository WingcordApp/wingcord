import SwiftUI
import WingcordCore

/// A channel read *beside* the page that pointed at it.
///
/// **The guide stays up.** A resource is a recommendation — "read this" — and
/// following one by replacing the page loses the list of the other four. So the
/// channel arrives in the column the roster and the profile pane already share,
/// and the guide keeps its place underneath the reader's eye.
///
/// **It is a preview, and it says so by what it offers.** There is no composer:
/// a 340-point column is not where anybody writes, and a text field that
/// technically works in a space that narrow is worse than none. What it has
/// instead is the one action a preview owes — opening the channel properly,
/// which is a real navigation and closes the page on the way.
struct ChannelPreviewContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        ChannelPreviewPane(
            chrome: model.channelPreviewChrome(for: channelID),
            open: { model.openChannelFromSurface(channelID) },
            close: { model.closeChannelPreview() }
        )
        .equatable()
    }
}

/// What the preview column's header draws. A plain value, like every other
/// surface's — the transcript underneath reads the store on its own.
struct ChannelPreviewChrome: Hashable, Sendable {
    var channelID: ChannelID
    var name: String
    var symbolName: String
    var topic: String?
}

struct ChannelPreviewPane: View, Equatable {
    var chrome: ChannelPreviewChrome

    static func == (lhs: ChannelPreviewPane, rhs: ChannelPreviewPane) -> Bool {
        lhs.chrome == rhs.chrome
    }

    var open: () -> Void = {}
    var close: () -> Void = {}

    var body: some View {
        ColumnTranscript(channelID: chrome.channelID) {
            ChannelPreviewHeader(chrome: chrome, open: open, close: close)
                .padding(.horizontal, Spacing.snug)
                .padding(.bottom, Spacing.base)
        }
        .frame(width: Proportions.previewColumnIdeal)
        // The column's own edge. The transcript beside it is the same opaque
        // ground, so without a line the two run together and the preview reads
        // as the page having grown a second column of text.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Ink.quaternary)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }
}

/// The name, and the two things a preview can do — the column's header, see
/// `ColumnHeader`.
struct ChannelPreviewHeader: View {
    var chrome: ChannelPreviewChrome
    /// Nil draws no Open — a message request is opened by accepting it.
    var open: (() -> Void)?
    var close: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                ColumnHeaderIdentity(name: chrome.name, help: chrome.topic ?? chrome.name) {
                    Image(symbol: chrome.symbolName)
                }
                Spacer(minLength: 0)
                if let open {
                    ColumnHeaderControl(
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        label: "Open Channel",
                        action: open
                    )
                }
                ColumnHeaderControl(systemImage: "xmark", label: "Close Preview", action: close)
            }
        }
    }
}
