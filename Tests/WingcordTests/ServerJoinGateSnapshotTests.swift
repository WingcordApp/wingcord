import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wingcord
@testable import WingcordCore

/// Writes pictures of the join surfaces, when asked.
///
/// **Off unless `WINGCORD_SNAPSHOTS` names a directory**, exactly like the
/// channel head's: a test that writes files on every run fails on a read-only
/// checkout, and these are for a person to look at rather than for CI to
/// compare. The assertions that hold the behaviour are in `ServerJoinGateTests`.
///
///     WINGCORD_SNAPSHOTS=/tmp/shots swift test --filter ServerJoinGateSnapshot
///
/// **What these can and cannot show.** `ImageRenderer` has no compositor, so
/// `.glassEffect` and `.ultraThinMaterial` render as nothing — the floating bar
/// and the card's material are absent from the picture by construction. What is
/// worth looking at here is the *layout*: the step's shape, the option grid's
/// columns, where the text wraps and whether anything is clipped.
@MainActor
@Suite("Server join gate snapshot")
struct ServerJoinGateSnapshotTests {

    @Test("Writes pictures of the gate's two kinds of step")
    func snapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_SNAPSHOTS"] else {
            return
        }
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )

        for (name, body) in [
            ("question", question),
            ("rules", rules),
        ] {
            try write(
                ServerJoinGatePane(presentation: presentation(body))
                    .background(Palette.canvas),
                to: "\(directory)/gate-\(name).png"
            )
        }

        try write(
            JoinServerSheet(
                state: joinSheetState,
                setInput: { _ in },
                join: {},
                dismiss: {}
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas),
            to: "\(directory)/join-sheet.png"
        )
    }

    // MARK: Fixtures

    private func presentation(
        _ body: ServerJoinGatePresentation.Body
    ) -> ServerJoinGatePresentation {
        let steps = 2
        let number: Int = switch body {
        case .question: 1
        case .rules: 2
        }
        let forward: ServerJoinGatePresentation.Forward = switch body {
        case .question: .next
        case .rules: .finish
        }
        return ServerJoinGatePresentation(
            guildID: GuildID(rawValue: 1000),
            serverName: "Forza Official",
            iconURL: nil,
            monogram: "FO",
            coverURL: nil,
            stepNumber: number,
            stepCount: steps,
            body: body,
            isSubmitting: false,
            failure: nil,
            canGoBack: number > 1,
            forward: forward
        )
    }

    private var question: ServerJoinGatePresentation.Body {
        .question(.init(
            promptID: 1,
            title: "Would you like to join any of our non-English speaking sections?",
            guidance: "Choose all that apply.",
            isRequired: false,
            options: [
                .init(id: 1, title: "Français",
                      detail: "Ajoute les chaines en Français à ta liste",
                      glyph: .character("🇫🇷"), isSelected: true, memberCount: 11_285),
                .init(id: 2, title: "Deutsch",
                      detail: "Fügt deutschsprachige Kanäle zu deiner Kanalliste hinzu",
                      glyph: .character("🇩🇪"), isSelected: false, memberCount: nil),
                .init(id: 3, title: "Español",
                      detail: "Añade los canales en español a tu lista de canales.",
                      glyph: .character("🇪🇸"), isSelected: false, memberCount: 6_741),
                .init(id: 4, title: "日本語",
                      detail: "チャンネルリストに日本語チャンネルを追加",
                      glyph: .character("🇯🇵"), isSelected: false, memberCount: nil),
            ],
            grants: "You will receive the @Forza FR role."
        ))
    }

    private var rules: ServerJoinGatePresentation.Body {
        .rules(.init(
            detail: "🎉 Welcome to the official Forza Discord Server! 🎉 This server has been "
                + "created to give you a centralized outlet for discussing Forza-related topics.",
            rules: [
                "🛑 This server has a ZERO tolerance policy for hate speech, violent acts, "
                    + "harassment, bullying and/or obscene imagery.",
                "🌐 Please read through the rules channel after joining.",
                "🇩🇪 Bitte lies dir nach dem Beitritt zum Server die Regeln durch.",
                "🇫🇷 Prenez le temps de lire les règles après avoir rejoint le serveur.",
                "🇪🇸 Por favor, lee las reglas después de unirte al servidor.",
                "🇯🇵 サーバーに参加するに当たって、ルールをご一読ください。",
            ]
        ))
    }

    private var joinSheetState: JoinServerSheetState {
        var state = JoinServerSheetState()
        state.input = "discord.gg/forza"
        state.lookup = .found(InvitePreview(
            code: "forza",
            guildID: GuildID(rawValue: 428_691_939_861_463_042),
            name: "Forza Official",
            description: "The official Discord server for the Forza Horizon and Forza "
                + "Motorsport series of videogames.",
            memberCount: 235_334,
            onlineCount: 48_014,
            features: ["VERIFIED"]
        ))
        return state
    }

    // MARK: Rendering

    /// **An offscreen window, not `ImageRenderer`.**
    ///
    /// `ImageRenderer` has no layout pass for a `ScrollView`: it renders the
    /// bar — a `safeAreaBar` sibling — and leaves the scrolling content empty,
    /// which photographs as a page that draws nothing and reads as a bug in the
    /// page. A real `NSWindow` with an `NSHostingView` in it lays out exactly as
    /// the app does, and `cacheDisplay` captures what the compositor produced,
    /// materials included.
    private func write(_ view: some View, to path: String) throws {
        let size = NSSize(width: 900, height: 660)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        // Ordering it in offscreen is what gives the hierarchy a real layout and
        // display cycle; a view with no window never lays its scroll views out.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap for \(path)")
            window.orderOut(nil)
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            Issue.record("could not encode \(path)")
            return
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
