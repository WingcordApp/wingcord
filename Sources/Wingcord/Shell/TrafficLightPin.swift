import AppKit
import ObjectiveC

/// Makes a window button answer every "go here" with where it is pinned.
///
/// **AppKit lays the title bar out inside the commit that draws it.** A change
/// of the window's title, of key status or of size marks the title bar for
/// layout, and that layout runs as the frame is being committed: it sets the
/// three buttons back to its own places one after another, and whatever moves
/// them back afterwards — a frame-change notification, a block on the next turn
/// of the run loop — runs with one frame already on its way to the screen. That
/// frame is the green light jumping out of line on every channel switch.
///
/// So the correction is made where it cannot be late: **in the setter.** The
/// button is given a subclass, made at run time the way key-value observing
/// makes one, whose `setFrameOrigin(_:)` and `frame` setter ask where the
/// button is pinned and pass that on instead of what they were handed. AppKit's
/// layout still runs and still "moves" the button; the move lands where the
/// shell wants it, in the same call, and there is no moment in between.
///
/// The button stays the system's own in every other way — its class's drawing,
/// hover, tracking and accessibility are inherited untouched, and `class`
/// still answers with the original, as an observed object's does.
@MainActor
enum TrafficLightPin {

    /// Where a pinned button goes: its origin in its superview, or nil to let
    /// AppKit's own place stand (full screen).
    typealias Target = @MainActor (NSButton) -> NSPoint?

    /// Pins `button`. Safe to call again: the subclass is made once per button
    /// class, and a button already wearing it only takes the new target.
    ///
    /// - Returns: false when the runtime would not make the subclass, in which
    ///   case the caller's own corrections are all there is.
    @discardableResult
    static func pin(_ button: NSButton, to target: @escaping Target) -> Bool {
        objc_setAssociatedObject(button, &targetKey, Box(target), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        guard let current: AnyClass = object_getClass(button) else { return false }
        if NSStringFromClass(current).hasPrefix(prefix) { return true }
        guard let pinned = subclass(of: current) else { return false }
        object_setClass(button, pinned)
        return true
    }

    private static let prefix = "WingcordPinned_"
    private nonisolated(unsafe) static var targetKey: UInt8 = 0

    private final class Box {
        let target: Target
        init(_ target: @escaping Target) { self.target = target }
    }

    /// The pinned origin for `object`, or `proposed` where it is not pinned.
    private nonisolated static func resolved(_ object: AnyObject, _ proposed: NSPoint) -> NSPoint {
        // AppKit lays out on the main thread; anything else is passed through.
        guard Thread.isMainThread else { return proposed }
        // On the main thread already, which is what makes handing it over sound.
        nonisolated(unsafe) let object = object
        return MainActor.assumeIsolated {
            guard let button = object as? NSButton,
                  let box = objc_getAssociatedObject(button, &targetKey) as? Box
            else { return proposed }
            return box.target(button) ?? proposed
        }
    }

    private static func subclass(of original: AnyClass) -> AnyClass? {
        let name = prefix + NSStringFromClass(original)
        if let made = objc_lookUpClass(name) { return made }
        guard let pinned = objc_allocateClassPair(original, name, 0) else { return nil }

        // `setFrameOrigin:` — the origin replaced.
        let setOrigin = #selector(NSView.setFrameOrigin(_:))
        if let method = class_getInstanceMethod(original, setOrigin) {
            typealias Call = @convention(c) (AnyObject, Selector, NSPoint) -> Void
            let inherited = unsafeBitCast(method_getImplementation(method), to: Call.self)
            let block: @convention(block) (AnyObject, NSPoint) -> Void = { object, point in
                inherited(object, setOrigin, resolved(object, point))
            }
            class_addMethod(pinned, setOrigin, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }

        // `setFrame:` — the origin replaced, the size kept.
        let setFrame = #selector(setter: NSView.frame)
        if let method = class_getInstanceMethod(original, setFrame) {
            typealias Call = @convention(c) (AnyObject, Selector, NSRect) -> Void
            let inherited = unsafeBitCast(method_getImplementation(method), to: Call.self)
            let block: @convention(block) (AnyObject, NSRect) -> Void = { object, frame in
                inherited(object, setFrame, NSRect(origin: resolved(object, frame.origin), size: frame.size))
            }
            class_addMethod(pinned, setFrame, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }

        // **The one AppKit itself calls.** The title bar places its buttons
        // through `_NSThemeWidget`'s own `setFrameOrigin:ignoreRentry:` —
        // read off a stack, `-[NSThemeFrame _updateButtonPositions]` — which
        // goes straight to `NSView`'s setter from there and so never reaches
        // the override above. It is also where the widget drops a move made
        // while it is already being moved, which is why a correction from a
        // frame-change notification was lost for the button it was about.
        // Absent on a system that has renamed it, and then the two above and
        // the caller's own corrections are what is left.
        let setOriginGuarded = NSSelectorFromString("setFrameOrigin:ignoreRentry:")
        if let method = class_getInstanceMethod(original, setOriginGuarded) {
            typealias Call = @convention(c) (AnyObject, Selector, NSPoint, ObjCBool) -> Void
            let inherited = unsafeBitCast(method_getImplementation(method), to: Call.self)
            let block: @convention(block) (AnyObject, NSPoint, ObjCBool) -> Void = { object, point, flag in
                inherited(object, setOriginGuarded, resolved(object, point), flag)
            }
            class_addMethod(pinned, setOriginGuarded, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }

        // `class` keeps answering with the button's own, as KVO's subclass does:
        // nothing that asks what kind of button this is should learn otherwise.
        let classSelector = NSSelectorFromString("class")
        if let method = class_getInstanceMethod(original, classSelector) {
            let block: @convention(block) (AnyObject) -> AnyClass = { _ in original }
            class_addMethod(pinned, classSelector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }

        objc_registerClassPair(pinned)
        return pinned
    }
}
