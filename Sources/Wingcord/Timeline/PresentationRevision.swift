import AppKit
import Combine
import Foundation
import Observation
import SwiftUI

/// One counter that moves whenever anything the drawn surfaces were laid out
/// against has changed.
///
/// **The layout caches key on it, so a counter that never moves is a cache that
/// is never invalidated.** The transcript's rows hold `CTFrame`s built against a
/// specific font, colour set and width; change the system appearance or the text
/// size and every one of them is stale — but nothing about the *messages*
/// changed, so no other key can see it.
///
/// What moves it:
///
///  - the system appearance (light ⇄ dark, Increase Contrast)
///  - the system text size
///  - the app's own text scale
///
/// A `@MainActor` observable singleton rather than an environment value: the
/// AppKit coordinators that need it are not views, and threading it through the
/// view tree only to hand it to a representable would make every view above the
/// transcript re-evaluate when the appearance changed.
@Observable
@MainActor
final class PresentationRevision {
    static let shared = PresentationRevision()

    /// Bumped on any change. Layout cache keys carry it.
    private(set) var value: UInt64 = 1

    /// The resolved drawing style, rebuilt when the revision moves.
    ///
    /// Held here rather than rebuilt per coordinator: `NSFont` lookup goes
    /// through the font manager and a paragraph style is an allocation, so two
    /// canvases building their own would do the work twice for an identical
    /// answer.
    private(set) var style: MessageTextStyle

    /// What the reader's preferences contribute to a laid-out row — density,
    /// whether embeds are measured, and the three date formatters.
    ///
    /// Here for the same reason the style is: a `DateFormatter` is expensive to
    /// configure and the transcript formats two or three timestamps per message,
    /// so building them anywhere but once per revision is doing the work again
    /// for an answer that cannot have changed.
    private(set) var timeline: TimelineSettings

    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        style = MessageTextStyle.current()
        timeline = TimelineSettings.current()

        let center = NotificationCenter.default
        // The system text size. On macOS this is the accessibility text-size
        // preference; a surface that ignores it is unreadable for the people who
        // most need it not to be.
        observers.append(center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { PresentationRevision.shared.invalidate() }
        })

        // Light ⇄ dark. Observed on the app rather than on a view, because the
        // canvases resolve their colours themselves and there is no view to hang
        // `viewDidChangeEffectiveAppearance` off.
        appearanceObservation = NSApp?.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated { PresentationRevision.shared.invalidate() }
        }
    }

    // No `deinit`. This is a process-lifetime singleton, so there is nothing to
    // tear down — and a `deinit` on a main-actor type cannot touch its own
    // main-actor storage anyway. The observers below are deliberately held for
    // the life of the app rather than balanced.

    /// Rebuilds the style and moves the counter.
    ///
    /// Guarded against a no-op: several of the signals above fire together on a
    /// single appearance change, and each bump discards every laid-out row in
    /// the app.
    func invalidate() {
        let rebuiltStyle = MessageTextStyle.current()
        let rebuiltTimeline = TimelineSettings.current()
        guard rebuiltStyle != style || rebuiltTimeline != timeline || value == 0 else { return }
        style = rebuiltStyle
        timeline = rebuiltTimeline
        value &+= 1
    }

    /// Called when a setting the drawn surfaces were laid out against changes —
    /// the app's text scale, message density, whether embeds are measured, the
    /// clock.
    ///
    /// Unguarded, unlike `invalidate()`: it is called from a `didSet` that has
    /// already established the value moved, and re-deriving both values only to
    /// compare them would be doing the work twice to learn what the caller
    /// already knew.
    func settingsDidChange() {
        style = MessageTextStyle.current()
        timeline = TimelineSettings.current()
        value &+= 1
    }
}

extension MessageTextStyle: Equatable {
    /// Compared on the values that decide LAYOUT, not on every field.
    ///
    /// A colour change repaints; a font change re-wraps. Including colours here
    /// would discard every `CTFrame` in the app to change a shade of grey, which
    /// is a full relayout for something a repaint would have covered — and
    /// `invalidate()` runs on every appearance signal, so that would be a
    /// relayout per signal.
    nonisolated static func == (lhs: MessageTextStyle, rhs: MessageTextStyle) -> Bool {
        lhs.bodyFont == rhs.bodyFont
            && lhs.authorFont == rhs.authorFont
            && lhs.metadataFont == rhs.metadataFont
            && lhs.codeFont == rhs.codeFont
            && lhs.lineSpacing == rhs.lineSpacing
            && lhs.paragraphSpacing == rhs.paragraphSpacing
            && lhs.emojiWidth == rhs.emojiWidth
    }
}
