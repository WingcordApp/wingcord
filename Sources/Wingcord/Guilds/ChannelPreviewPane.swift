import SwiftUI
import WingcordCore

/// A channel read *beside* the page that pointed at it.
///
/// **The guide stays up.** A resource is a recommendation — "read this" — and
/// following one by replacing the page loses the list of the other four. So the
/// channel arrives in the column the roster and the profile pane already share,
/// and the guide keeps its place underneath the reader's eye.
///
/// **The forum post's column, exactly** (Alex, 2026-11-18: "what if you used
/// the same sidebar as on the forum sidebar"): the same transcript, the same
/// composer at its foot, the same 460 points — so a channel opened from the
/// guide, Browse Channels or Channels & Roles can be answered where it is
/// read. Its header still offers opening the channel properly, a real
/// navigation that closes the page on the way.
///
/// It had no composer, and the empty foot it was built with is what broke it:
/// a bottom bar laid out around nothing took the column's whole height and
/// left the transcript zero points tall (measured in the demo), its rows
/// spilling out at the top over an empty column.
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
        } foot: {
            // The forum post column's foot (`ThreadPanel`).
            VStack(spacing: 0) {
                ComposerStatusRow(channelID: chrome.channelID)
                ComposerContainer(channelID: chrome.channelID)
            }
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
