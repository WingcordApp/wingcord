import SwiftUI
import WingcordCore

/// An application's storefront, as a catalogue.
///
/// **Nothing here takes money.** Every price is a button that opens Discord's
/// own store page in the browser, where the reader's payment methods and
/// Discord's protections live. A third-party client reproducing a checkout is a
/// third-party client asking for card details, and the one honest version of
/// that control is the one that hands the job back — which is also why the label
/// says where it goes rather than "Buy".
///
/// The page is reached from an app's own page and returns to it, which is the
/// same one-deep move the detail page already makes from the directory.
struct ApplicationStorePage: View {
    var applicationID: ApplicationID
    var name: String
    var onBack: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// The tile whose sheet is open. **A sheet, not a fourth page**: the modal
    /// is where the artwork is finally large enough to be worth showing, and a
    /// third level of back-stack inside a 388-point popover is a maze.
    @State private var opened: StoreListing?

    private var store: ApplicationStore? {
        // Read before the lookup so the memo registers its dependency.
        let _ = model.storeRevision
        return model.applicationStores[applicationID]
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
            BackControl(action: onBack)
        }
        .task(id: applicationID) {
            await model.sessionController.loadApplicationStore(applicationID)
        }
        .sheet(item: $opened) { listing in
            StoreListingSheet(
                listing: listing,
                applicationID: applicationID,
                applicationName: name,
                termsOfServiceURL: model.activityApp(applicationID)?.termsOfServiceURL,
                privacyPolicyURL: model.activityApp(applicationID)?.privacyPolicyURL,
                onPurchase: openStore
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if let store {
            if store.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.group) {
                        if !store.subscriptions.isEmpty {
                            section("Subscriptions") {
                                ForEach(store.subscriptions) { listing in
                                    StoreTile(
                                        listing: listing,
                                        applicationID: applicationID,
                                        onOpen: { opened = listing }
                                    )
                                }
                            }
                        }
                        if !store.items.isEmpty {
                            section("Items") {
                                ForEach(store.items) { listing in
                                    StoreTile(
                                        listing: listing,
                                        applicationID: applicationID,
                                        onOpen: { opened = listing }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.snug)
                    .padding(.top, Metrics.control + Spacing.group)
                    .padding(.bottom, Spacing.margin)
                }
                .scrollIndicators(.never)
                .softScrollEdgesVertical()
            }
        } else {
            ProgressView().controlSize(.small).frame(maxHeight: .infinity)
        }
    }

    private func section(
        _ title: String,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(title)
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.secondary)
                .textCase(.uppercase)
                .kerning(0.4)
                .padding(.leading, Spacing.tight)
            rows()
        }
    }

    private var empty: some View {
        VStack(spacing: Spacing.base) {
            Spacer()
            Image(systemName: "bag")
                .font(.system(size: 26))
                .foregroundStyle(Ink.quaternary)
            Text("\(name) has nothing for sale")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, Spacing.group)
        .frame(maxWidth: .infinity)
    }

    private func openStore() {
        guard let url = store?.purchaseURL() else { return }
        openURL(url)
    }
}

// MARK: - One tile

/// A row in the catalogue: artwork, name, and what it costs.
///
/// **Compact, because the detail lives in the sheet.** The capture's own grid
/// shows a picture, a name, two lines and a price; everything else — the
/// benefits, the full description, the policies — is behind the tap.
private struct StoreTile: View {
    var listing: StoreListing
    var applicationID: ApplicationID
    var onOpen: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Spacing.snug) {
                StoreArtwork(applicationID: applicationID, assetID: listing.assetID, side: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(listing.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if !listing.summary.isEmpty {
                        Text(listing.summary)
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: Spacing.base)
                if let price = listing.price {
                    Text(price.formatted)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(Spacing.snug)
            .background(
                isHovered ? Palette.hoverFill : Palette.surfaceRaised,
                in: .rect(cornerRadius: Radius.chip, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .accessibilityLabel(Text(listing.name))
        .accessibilityValue(Text(listing.price?.formatted ?? ""))
    }
}

// MARK: - One tile, opened

/// The modal the capture opens on a tile: the artwork at full width, what the
/// thing is, and the one control that leaves for the browser.
private struct StoreListingSheet: View {
    var listing: StoreListing
    var applicationID: ApplicationID
    var applicationName: String
    var termsOfServiceURL: URL?
    var privacyPolicyURL: URL?
    var onPurchase: () -> Void

    @Environment(\.dismiss) private var dismiss

    private static let width: CGFloat = 420
    private static let artHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    art
                    if listing.isSubscription {
                        // The capture labels a subscription and leaves an item
                        // unlabelled, which is the right way round: "buy once"
                        // is what a price already says, and "bills you every
                        // month" is not.
                        chip("Personal subscription", systemImage: "person.fill")
                    }
                    Text(listing.name)
                        .font(.system(.title2, weight: .bold))
                        .foregroundStyle(Ink.primary)
                    if !listing.summary.isEmpty {
                        Text(listing.summary)
                            .font(.system(.subheadline))
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !listing.benefits.isEmpty { benefits }
                }
                .padding(.horizontal, Spacing.margin)
                .padding(.bottom, Spacing.margin)
            }
            .scrollIndicators(.never)
            .softScrollEdgesVertical()
            footer
        }
        .frame(width: Self.width)
        .frame(maxHeight: 560)
    }

    private var header: some View {
        HStack(spacing: Spacing.base) {
            Text(applicationName)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.snug)
    }

    private var art: some View {
        Color.clear
            .frame(height: Self.artHeight)
            .overlay {
                StoreArtwork(
                    applicationID: applicationID,
                    assetID: listing.assetID,
                    side: Self.width,
                    corner: 0
                )
                .aspectRatio(contentMode: .fit)
            }
            .background(Palette.surfaceRaised)
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
    }

    private func chip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
            .background(Palette.surfaceRaised, in: .capsule)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Divider().overlay(Palette.hoverFill)
            Text("EXCLUSIVE TO THIS TIER")
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.tertiary)
            ForEach(listing.benefits) { benefit in
                HStack(alignment: .top, spacing: Spacing.snug) {
                    StoreArtwork(
                        applicationID: applicationID,
                        assetID: benefit.assetID,
                        side: 28
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(benefit.name)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                        if !benefit.summary.isEmpty {
                            Text(benefit.summary)
                                .font(Typeface.rowSubtitle)
                                .foregroundStyle(Ink.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, Spacing.tight)
    }

    private var footer: some View {
        HStack(spacing: Spacing.base) {
            if termsOfServiceURL != nil || privacyPolicyURL != nil {
                HStack(spacing: Spacing.tight) {
                    if let terms = termsOfServiceURL { Link("Terms of Service", destination: terms) }
                    if termsOfServiceURL != nil, privacyPolicyURL != nil {
                        Text("•").foregroundStyle(Ink.quaternary)
                    }
                    if let privacy = privacyPolicyURL { Link("Privacy Policy", destination: privacy) }
                }
                .font(Typeface.rowSubtitle)
                .tint(Palette.accent)
            }
            Spacer(minLength: Spacing.base)
            PurchaseControl(label: purchaseLabel, action: onPurchase)
                .fixedSize()
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.snug)
        .background(Palette.surface)
    }

    /// "Subscribe for $4.99 / Month", "Buy for $24.99", or — where the price
    /// route did not answer — a label that promises no number.
    private var purchaseLabel: String {
        guard let price = listing.price else { return "View in store" }
        guard listing.isSubscription else { return "Buy for \(price.formatted)" }
        guard let interval = listing.interval else { return "Subscribe for \(price.formatted)" }
        return "Subscribe for \(price.formatted) / \(interval.label)"
    }
}

// MARK: - Shared pieces

/// The control that leaves for the browser.
///
/// **It says where it goes.** A button reading "Buy for $24.99" inside a client
/// that cannot take money is the inert control `INVARIANTS.md` §5.5 forbids
/// wearing a price; the glyph is what makes the destination part of the label
/// rather than a surprise.
private struct PurchaseControl: View {
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.tight) {
                Text(label)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(.caption))
            }
            .foregroundStyle(.white)
            // **Padding first, then the width.** The store page gives this the
            // full column and the sheet's footer pins it to its own size — and
            // with only `maxWidth: .infinity` the second case collapses to the
            // label's intrinsic width with the capsule drawn right against the
            // words.
            .padding(.horizontal, Spacing.margin)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.control)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .emphasisChrome(Palette.accent)
        .help("Opens Discord's store in your browser")
        .accessibilityHint(Text("Opens Discord's store in your browser"))
    }
}

private struct StoreArtwork: View {
    var applicationID: ApplicationID
    var assetID: String?
    var side: CGFloat
    var corner: CGFloat?

    var body: some View {
        RemoteImage(
            url: assetID.flatMap {
                CDN.storeAsset(id: applicationID, assetID: $0, width: side)
            },
            side: side,
            bucket: .artwork
        ) {
            Color.clear
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: corner ?? (side * 0.22), style: .continuous))
        .accessibilityHidden(true)
    }
}
