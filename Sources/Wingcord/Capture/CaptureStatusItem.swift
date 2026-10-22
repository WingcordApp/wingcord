import AppKit

/// The menu bar's sign that a recording is running, and the way to end it
/// from anywhere — beside the system's own screen-recording indicator, which
/// says *that* the screen is being recorded; this says by whom, for how long,
/// and stops it.
@MainActor
final class CaptureStatusItem: NSObject {
    private weak var controller: CaptureController?
    private var item: NSStatusItem?
    private var timer: Timer?
    private var started = Date.now

    init(controller: CaptureController) {
        self.controller = controller
    }

    func show() {
        started = .now
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
        item.button?.contentTintColor = .systemRed
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Stop Recording", action: #selector(stop), keyEquivalent: "").targeting(self))
        menu.addItem(NSMenuItem(title: "Discard Recording", action: #selector(discard), keyEquivalent: "").targeting(self))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Clips Folder", action: #selector(openFolder), keyEquivalent: "").targeting(self))
        item.menu = menu
        self.item = item
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func tick() {
        let elapsed = Duration.seconds(Date.now.timeIntervalSince(started).rounded(.down))
        item?.button?.title = " " + elapsed.formatted(.time(pattern: .minuteSecond))
    }

    @objc private func stop() {
        guard let controller else { return }
        Task { await controller.stopRecording() }
    }

    @objc private func discard() {
        controller?.discardRecording()
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: ClipLibrary.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ClipLibrary.folder)
    }
}

private extension NSMenuItem {
    func targeting(_ target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
