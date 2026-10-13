import AppKit
import Testing
@testable import Wingcord

/// The picker's drawn grid over its scroll view: wherever the picker opens, the
/// canvas must cover what the clip view shows.
@MainActor
@Suite("Expression grid viewport")
struct ExpressionGridViewportTests {

    private func section(_ id: String, count: Int) -> ExpressionSection {
        ExpressionSection(
            id: id,
            title: id,
            badge: .glyph("😀"),
            items: (0..<count).map {
                ExpressionItem(id: "\(id).\($0)", art: .glyph("😀"), name: "e\($0)", pick: .insert("😀"))
            }
        )
    }

    private var sections: [ExpressionSection] { (0..<12).map { section("s\($0)", count: 40) } }

    private struct Host {
        var coordinator: ExpressionGridCoordinator
        var scrollView: NSScrollView
        var window: NSWindow

        var canvas: NSView? { scrollView.documentView?.subviews.first }

        /// Whether the canvas covers the part of the clip view that has
        /// document under it.
        var covers: Bool {
            guard let canvas, let document = scrollView.documentView else { return false }
            let clip = scrollView.contentView.bounds
            let top = max(clip.minY, 0)
            let bottom = min(clip.maxY, document.frame.height)
            guard bottom > top else { return true }
            return canvas.frame.minY <= top + 0.5 && canvas.frame.maxY >= bottom - 0.5
                && abs(canvas.bounds.minY - canvas.frame.minY) < 0.5
        }

        /// Whether the clip view is inside the range a reader can scroll to:
        /// never above the content's rest under the chrome.
        func isInRange(topInset: CGFloat) -> Bool {
            scrollView.contentView.bounds.minY >= -topInset - 0.5
        }

        var report: String {
            "clip \(scrollView.contentView.bounds) doc \(scrollView.documentView?.frame ?? .zero) canvas \(canvas?.frame ?? .zero)"
        }
    }

    private func host() -> Host {
        let coordinator = ExpressionGridCoordinator()
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 440),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 440))
        window.contentView = container
        scrollView.frame = .zero
        container.addSubview(scrollView)
        return Host(coordinator: coordinator, scrollView: scrollView, window: window)
    }

    @Test("Opening: layout before size, then the chrome's inset")
    func openPlain() {
        let host = host()
        host.coordinator.update(sections: sections, mode: .emoji, topInset: 0, animates: false, jump: nil)
        host.scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 440)
        host.coordinator.update(sections: sections, mode: .emoji, topInset: 120, animates: false, jump: nil)
        #expect(host.covers, "\(host.report)")
        #expect(host.isInRange(topInset: 120), "\(host.report)")
    }

    @Test("Opening at a section before the grid has a size")
    func openAtSectionEarly() {
        let host = host()
        let jump = ExpressionJump(section: 5, token: 1)
        host.coordinator.update(sections: sections, mode: .stickers, topInset: 0, animates: false, jump: jump)
        host.scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 440)
        host.coordinator.update(sections: sections, mode: .stickers, topInset: 120, animates: false, jump: jump)
        #expect(host.covers, "\(host.report)")
        #expect(host.isInRange(topInset: 120), "\(host.report)")
    }

    @Test("Opening at a section once sized")
    func openAtSectionLate() {
        let host = host()
        host.coordinator.update(sections: sections, mode: .stickers, topInset: 0, animates: false, jump: nil)
        host.scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 440)
        host.coordinator.update(sections: sections, mode: .stickers, topInset: 120, animates: false, jump: nil)
        host.coordinator.update(
            sections: sections, mode: .stickers, topInset: 120, animates: false,
            jump: ExpressionJump(section: 5, token: 1)
        )
        #expect(host.covers, "\(host.report)")
        #expect(host.isInRange(topInset: 120), "\(host.report)")
    }

    @Test("Opening while the popover grows")
    func openGrowing() {
        let host = host()
        host.coordinator.update(sections: sections, mode: .emoji, topInset: 0, animates: false, jump: nil)
        host.scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        host.coordinator.update(sections: sections, mode: .emoji, topInset: 120, animates: false, jump: nil)
        for height in stride(from: 100.0, through: 440.0, by: 60) {
            host.scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: height)
        }
        host.scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 440)
        #expect(host.covers, "\(host.report)")
        #expect(host.isInRange(topInset: 120), "\(host.report)")
    }

    @Test("The inset arriving before the size")
    func insetFirst() {
        let host = host()
        host.coordinator.update(sections: sections, mode: .emoji, topInset: 120, animates: false, jump: nil)
        host.scrollView.frame = CGRect(x: 0, y: 0, width: 400, height: 440)
        #expect(host.covers, "\(host.report)")
        #expect(host.isInRange(topInset: 120), "\(host.report)")
    }
}
