import SwiftUI
import WingcordCore

/// The popout's hero — Discord's `cE` + `cT`: the artwork's two colours as a
/// 45° gradient under white words, the picture (a game's **portrait cover** at
/// its own shape), the title, the subtitle, the markers, the corner mark, then
/// the store or the song's progress.
struct ActivityPopoutHero: View {
    var popout: ActivityPopoutPresentation
    var tint: ActivityCardTint?
    var open: (ActivityPopoutPresentation.Destination) -> Void

    private static let artWidth: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(alignment: .center, spacing: 14) {
                art
                VStack(alignment: .leading, spacing: 2) {
                    link(popout.titleDestination) {
                        Text(popout.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    if let subtitle = popout.subtitle {
                        link(popout.subtitleDestination) {
                            Text(subtitle)
                                .font(.system(size: 14))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .lineLimit(2)
                        }
                    }
                    if !popout.markers.isEmpty {
                        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                            ActivityMarkerFlow(
                                markers: popout.markers,
                                liveSince: popout.liveSince,
                                occurredAt: popout.occurredAt,
                                now: context.date
                            )
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.trailing, popout.corner == nil ? 0 : 22)
                Spacer(minLength: 0)
            }
            .overlay(alignment: .topTrailing) { corner }
            if let span = popout.songSpan {
                ActivitySongProgress(span: span)
            }
            store
        }
        .padding(Spacing.snug)
        .background { ground }
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
    }

    /// The gradient, or Discord's dark surface until the colours are read.
    private var ground: some View {
        let pair = tint ?? ActivityCardTint(primary: InviteCardColours.neutral, secondary: InviteCardColours.neutral)
        return LinearGradient(
            colors: [Color(hex: pair.primary), Color(hex: pair.secondary)],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }

    @ViewBuilder
    private var art: some View {
        let height = popout.artIsCover ? Self.artWidth * 4 / 3 : Self.artWidth
        link(popout.titleDestination) {
            RemoteImage(url: popout.artURL, side: popout.artIsCover ? height : Self.artWidth, bucket: .thumbnail) {
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.08))
                    Image(systemName: popout.artSymbol)
                        .font(.system(size: 22))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .aspectRatio(contentMode: .fill)
            .frame(width: Self.artWidth, height: height)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var corner: some View {
        if let corner = popout.corner, BrandMark.mark(for: corner.service) != nil {
            let mark = BrandGlyph(service: corner.service)
                .fill(.white)
                .frame(width: 18, height: 18)
                .opacity(0.9)
            if let destination = corner.destination {
                Button { open(destination) } label: { mark.contentShape(.rect) }
                    .buttonStyle(.plain)
                    .help(corner.label)
                    .accessibilityLabel(Text(corner.label))
            } else {
                mark
                    .help(corner.label)
                    .accessibilityLabel(Text(corner.label))
            }
        }
    }

    /// "Get on Steam" — one store a button, two a Play menu (`607781`). Glass,
    /// Alex's rule for buttons, where Discord's is solid white.
    @ViewBuilder
    private var store: some View {
        if popout.storeOffers.count == 1, let offer = popout.storeOffers.first {
            Button { open(.link(offer.url)) } label: { storeLabel(offer.store, offer.store.callToAction) }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .help("Open \(offer.store.title) in your browser")
        } else if popout.storeOffers.count > 1 {
            Menu {
                ForEach(popout.storeOffers) { offer in
                    Button(offer.store.title) { open(.link(offer.url)) }
                }
            } label: {
                storeLabel(nil, "Play")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity)
        }
    }

    private func storeLabel(_ store: GameStore?, _ text: String) -> some View {
        HStack(spacing: 6) {
            if let store {
                BrandGlyph(service: store.brandService).fill(.white).frame(width: 15, height: 15)
            }
            Text(text).font(.system(.subheadline, weight: .semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func link<Label: View>(
        _ destination: ActivityPopoutPresentation.Destination?,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if let destination {
            Button { open(destination) } label: { label().contentShape(.rect) }
                .buttonStyle(.plain)
                .pointerStyle(.link)
        } else {
            label()
        }
    }
}

/// A live song's place in it: a thin bar and the time, Discord's `ul`.
struct ActivitySongProgress: View {
    var span: ClosedRange<Date>

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            let total = span.upperBound.timeIntervalSince(span.lowerBound)
            let elapsed = min(max(0, context.date.timeIntervalSince(span.lowerBound)), total)
            HStack(spacing: Spacing.base) {
                Text(Self.clock(elapsed))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(.white).frame(width: proxy.size.width * (total > 0 ? elapsed / total : 0))
                    }
                }
                .frame(height: 4)
                Text(Self.clock(total))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.85))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(Self.clock(elapsed)) of \(Self.clock(total))"))
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
