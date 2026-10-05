import AppKit
import SwiftUI

/// What stands where the composer would when a conversation cannot be written
/// in — Discord's chat blocker (`786051`): a sentence saying why, a line under
/// it where Discord has one, and the one thing that would change it.
///
/// **A statement and a way out, not a disabled field.** A greyed composer
/// invites a click that can only fail; this says what is in the way and offers
/// the only remedy, as Discord's does — Unblock for a person the reader
/// blocked, Learn More in Discord's own system messages. Its button is
/// Discord's secondary one.
struct ComposerBlocker: View {
    var message: String
    var subtitle: String? = nil
    /// Discord's picture at the leading edge, where it has one.
    var image: NSImage? = nil
    var buttonTitle: String
    var isBusy = false
    var action: () -> Void

    var body: some View {
        HStack(spacing: Spacing.snug) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 41, height: 36)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MessageRequestButton(title: buttonTitle, isProminent: false, isBusy: isBusy, action: action)
        }
        .padding(Spacing.snug)
        .glassEffect(.clear, in: .rect(cornerRadius: Radius.glass))
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
    }
}

/// Discord's picture for its own system messages' blocker, read once.
enum SystemDirectMessageArt {
    @MainActor static let image: NSImage? = Bundle.module
        .url(forResource: "system-dm", withExtension: "svg", subdirectory: "Art")
        .flatMap(NSImage.init(contentsOf:))
}
