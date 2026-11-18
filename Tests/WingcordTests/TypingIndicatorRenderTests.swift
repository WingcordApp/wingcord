import AppKit
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// The typing line, drawn offscreen — with `WINGCORD_RENDER_DIR` set, each case
/// is written there as a PNG to look at; without it the cases still lay out,
/// which is what catches a line that collapses to nothing.
@MainActor
@Suite("Typing indicator renders")
struct TypingIndicatorRenderTests {

    private let style = TypingIndicatorStyle(
        emojis: [EmojiRef(name: "❤️"), EmojiRef(name: "✨"), EmojiRef(name: "💬")],
        animation: .wave,
        suggestion: .yapping
    )

    @Test("The plain line, a custom one, and two typers drawing the plain one")
    func renders() throws {
        let cases: [(String, TypingIndicator)] = [
            ("typing-plain", TypingIndicator(names: ["Ana"])),
            ("typing-custom", TypingIndicator(names: ["Ana"], style: style)),
            ("typing-two", TypingIndicator(names: ["Ana", "Ben"], style: nil)),
        ]
        for (name, view) in cases {
            let size = try render(view, named: name)
            #expect(size.height > 10, "\(name) laid out")
        }
    }

    @Test("The editor flyout lays out with a style and without one")
    func rendersFlyout() throws {
        let profile = ProfilePresentation(
            userID: UserID(rawValue: 1), displayName: "alex", handle: "alexsample", monogram: "A",
            status: .online, isBot: false, badges: [], roles: [], accountCreated: .distantPast,
            isSelf: true, connections: [], premiumTier: .none, mutualServers: [], mutualFriends: [],
            isProfilePrivate: false, note: "", isLoading: false
        )
        for (name, current) in [("typing-flyout-new", nil), ("typing-flyout-worn", style)] as [(String, TypingIndicatorStyle?)] {
            let editor = ProfileEditor(profile: profile, widgets: [], scope: .account, typingIndicatorStyle: current)
            let flyout = TypingIndicatorFlyout(editor: editor)
            let size = try render(flyout, named: name, width: nil)
            #expect(size.width >= 380)
        }
    }

    /// Lays the view out on the transcript's dark ground and, when asked,
    /// writes it out at 2×.
    private func render(_ view: some View, named name: String, width: CGFloat? = 360) throws -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width).padding(12).background(Color(white: 0.11)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"],
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return host.bounds.size }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        return host.bounds.size
    }
}
