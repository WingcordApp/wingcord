import SwiftUI
import WingcordCore

/// A transcript in the window's right-hand column, under every bar that floats
/// over it — the window's chrome, the column's own header and its foot.
///
/// **The rows run beneath all three and pay for them as content insets**, which
/// is `ConversationPane`'s arrangement brought to the column. Left inside the
/// safe area, the scroll view stopped short of each bar, so the header's and the
/// composer's glass had the opaque reading surface behind it and nothing to
/// refract — the flat slab both bars looked like — and the strip under the
/// window's toolbar ended on a hard seam beside the transcript that does run
/// under it.
///
/// Every inset is measured rather than written down: the header grows with a
/// spam question and the foot with a reply banner, and a constant is wrong the
/// moment either happens.
struct ColumnTranscript<Header: View, Foot: View>: View {
    var channelID: ChannelID
    @ViewBuilder var header: Header
    @ViewBuilder var foot: Foot

    /// The window's chrome above the column.
    ///
    /// **Read at this view's root, which respects the safe area** — only the
    /// transcript inside ignores it. A reader that ignored the inset would have
    /// been handed the region it describes and report zero, and one read inside
    /// the header's bar would count the header twice.
    @State private var chromeHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var footHeight: CGFloat = 0

    var body: some View {
        TimelineContainer(
            channelID: channelID,
            topInset: chromeHeight + headerHeight,
            bottomInset: footHeight
        )
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .floatingTopBar {
            header.onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                Self.write($0, into: $headerHeight)
            }
        }
        // `safeAreaBar`, not `safeAreaInset`: the foot registers as a bar, which
        // is what the scroll edge effect keys off — see `floatingTopBar`.
        .safeAreaBar(edge: .bottom, spacing: 0) {
            foot.onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                Self.write($0, into: $footHeight)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: {
            Self.write($0, into: $chromeHeight)
        }
    }

    /// Stores a measured value, guarded and unanimated.
    ///
    /// Guarded because a `@State` write of an equal value still invalidates, and
    /// all three are read on every layout pass. Unanimated because a measurement
    /// changes mid-resize and as the composer grows a line, and animating on one
    /// makes the transcript lurch. §3.
    private static func write(_ value: CGFloat, into binding: Binding<CGFloat>) {
        guard abs(binding.wrappedValue - value) > 0.5 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { binding.wrappedValue = value }
    }
}

extension ColumnTranscript where Foot == EmptyView {
    /// A column that only reads — a preview has no composer.
    init(channelID: ChannelID, @ViewBuilder header: () -> Header) {
        self.init(channelID: channelID, header: header, foot: { EmptyView() })
    }
}
