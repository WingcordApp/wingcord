import AppKit
import SwiftUI

/// The running activity in a window of its own (Discord's Pop Out).
///
/// **A standard titled window, not a HUD** (HIG panels: "Prefer standard
/// panels"; a detached popover "minimally changes" its look): resizable, its
/// title the app's name, closing it brings the activity back into the main
/// window. The web view is moved into it, never reloaded.
@MainActor
final class ActivityPopoutWindow: NSObject, NSWindowDelegate {
    static let shared = ActivityPopoutWindow()

    private var window: NSWindow?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        guard let running = model.runningActivity else { return }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 480, height: 300)
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.title = running.name
        window?.contentView = NSHostingView(rootView: ActivityPopoutContent().environment(model))
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window?.contentView = nil
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        model?.isActivityPoppedOut = false
    }
}

/// What the popped-out window shows: the frame, filling it.
private struct ActivityPopoutContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Palette.surface
            if model.activityHost == .popout, let runtime = model.activityRuntime {
                ActivityWebView(runtime: runtime)
            }
        }
        .ignoresSafeArea()
        // The activity ended (left, or it closed itself): the window goes too.
        .onChange(of: model.runningActivity == nil) { _, ended in
            if ended { model.popInActivity() }
        }
    }
}
