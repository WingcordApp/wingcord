import AppKit
import SwiftUI
import Testing
import WingcordCore
@testable import WingcordNet
@testable import Wingcord

/// The settings windows as windows: the real views in an offscreen `NSWindow`
/// with the scene's toolbar bridged, driven through the outline's own
/// selection and the keys a hand would press.
///
/// **No synthesised clicks.** One `mouseDown` sent to a window in this process
/// makes AppKit stop the main run loop some time later, and the test runner's
/// async main then exits 0 before it has printed a result — a truncated run
/// that reads as a pass. A click on an action row was driven once by hand
/// (2026-10-06: Members acted and left the selection where it was); what stays
/// here is everything that does not need one.
///
/// **Not the window title.** No offscreen `NSHostingController` bridges a
/// `navigationTitle` — not even one on a bare `Text` — so the title is the one
/// part of the window these cannot reach; a `Window` scene sets it.
@MainActor
@Suite("Settings windows", .serialized)
struct SettingsWindowTests {

    init() {
        _ = NSApplication.shared
    }

    // MARK: Settings

    @Test("Choosing a sidebar row opens its pane, and ⌘[ and ⌘] walk the history")
    func sidebarAndHistory() throws {
        try withRememberedSection(.appearance) {
            let window = mount(SettingsView().resolvesMotion().environment(AppModel()))
            defer { window.close() }
            let list = try #require(outline(in: window))

            select(row: Self.row(of: .voiceVideo), in: list)
            #expect(SettingsWindow.lastSection == .voiceVideo)

            press("[", keyCode: 33, in: window)
            #expect(SettingsWindow.lastSection == .appearance)

            press("]", keyCode: 30, in: window)
            #expect(SettingsWindow.lastSection == .voiceVideo)
        }
    }

    @Test("A request for a page moves a window that is already open")
    func requestMovesAnOpenWindow() {
        withRememberedSection(.general) {
            let window = mount(SettingsView().resolvesMotion().environment(AppModel()))
            defer { window.close() }

            SettingsWindow.request(.privacy)
            settle()
            #expect(SettingsWindow.lastSection == .privacy)
        }
    }

    @Test("Only a pane with an action puts one in the toolbar")
    func paneActionOnlyWhereThereIsOne() {
        withRememberedSection(.account) {
            let window = mount(SettingsView().resolvesMotion().environment(AppModel()))
            defer { window.close() }
            #expect(toolbarLabels(of: window) == ["Back", "Forward", "Sign Out"])
        }
        withRememberedSection(.general) {
            let window = mount(SettingsView().resolvesMotion().environment(AppModel()))
            defer { window.close() }
            #expect(toolbarLabels(of: window) == ["Back", "Forward"])
        }
    }

    // MARK: Server Settings

    @Test("A page row selects, and an action row is never selected")
    func serverSidebarPagesAndActions() throws {
        let store = ServerSettingsStore(
            guildID: GuildID(rawValue: 1),
            permissions: .administrator,
            channels: [],
            rest: DiscordREST(protocolClasses: [OfflineProtocol.self])
        )
        let probe = SidebarProbe()
        let window = mount(ServerSidebarHost(store: store, probe: probe))
        defer {
            store.cancelAll()
            window.close()
        }
        let list = try #require(outline(in: window))

        select(row: Self.serverRow(of: .roles), in: list)
        #expect(probe.selection == .roles)

        // Members is a button in the list, not a page: choosing its row leaves
        // the page where it was, and acting is the button's job.
        select(row: Self.serverRow(of: .members), in: list)
        #expect(probe.selection == .roles)
        #expect(probe.acted.isEmpty)
    }

    // MARK: Rows

    /// A row's index in the sidebar's outline: each group is a spacer row and
    /// then its sections, in the catalog's order.
    private static func row(of section: SettingsSection) -> Int {
        var row = 0
        for group in SettingsSection.groups {
            row += 1
            if let index = group.firstIndex(of: section) { return row + index }
            row += group.count
        }
        return -1
    }

    /// The same for a server's sidebar: the server's own header row, then each
    /// group's header (or spacer) row and its sections — every section an
    /// administrator reaches before the server's settings have arrived.
    private static func serverRow(of section: ServerSettingsSection) -> Int {
        var row = 1
        for group in ServerSettingsSection.groups {
            let sections = group.sections.filter { $0 != .deleteServer }
            guard !sections.isEmpty else { continue }
            row += 1
            if let index = sections.firstIndex(of: section) { return row + index }
            row += sections.count
        }
        return -1
    }

    // MARK: Driving

    private func mount(_ root: some View) -> NSWindow {
        let host = NSHostingController(rootView: root)
        host.sceneBridgingOptions = [.toolbars]
        let window = KeyWindow(contentViewController: host)
        // Closed by the test and released by ARC — never by AppKit as well.
        window.isReleasedWhenClosed = false
        window.styleMask.insert(.fullSizeContentView)
        window.setFrame(NSRect(x: -6000, y: -6000, width: 739, height: 699), display: true)
        window.orderFrontRegardless()
        settle()
        return window
    }

    private func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func outline(in window: NSWindow) -> NSTableView? {
        window.contentView.flatMap { descendants(of: $0, as: NSTableView.self).first }
    }

    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { sub -> [T] in
            ((sub as? T).map { [$0] } ?? []) + descendants(of: sub, as: type)
        }
    }

    private func toolbarLabels(of window: NSWindow) -> [String] {
        (window.toolbar?.items ?? []).map(\.label).filter { !$0.isEmpty }
    }

    /// Chooses a row as a click ends: through the outline's own selection,
    /// which posts the change the list's binding listens for.
    private func select(row: Int, in list: NSTableView) {
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        settle(0.3)
    }

    private func press(_ key: String, keyCode: UInt16, in window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: key, charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: keyCode
        ) else { return }
        _ = window.performKeyEquivalent(with: event)
        settle(0.3)
    }

    /// Runs `body` with the window's remembered pane set to `section`, and puts
    /// back whatever the defaults held before.
    private func withRememberedSection(_ section: SettingsSection, _ body: () throws -> Void) rethrows {
        let key = "settings.lastSection"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        SettingsWindow.lastSection = section
        try body()
    }
}

/// A window that answers as the key window without the window server making
/// it one, so a key equivalent reaches the toolbar as it would in the reader's
/// front window — and the reader's own focus is never taken to do it.
private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

/// What the server sidebar under test did.
@MainActor
private final class SidebarProbe {
    var selection: ServerSettingsSection = .profile
    var acted: [ServerSettingsSection] = []
}

private struct ServerSidebarHost: View {
    let store: ServerSettingsStore
    let probe: SidebarProbe
    @State private var selection: ServerSettingsSection = .profile
    @State private var query = ""

    var body: some View {
        NavigationSplitView {
            ServerSettingsSidebar(
                store: store,
                guildName: "Test Server",
                guildIconURL: nil,
                isOwner: true,
                selection: $selection,
                query: $query,
                act: { probe.acted.append($0) }
            )
        } detail: {
            Text("Page")
        }
        .onChange(of: selection) { _, section in probe.selection = section }
    }
}

/// Answers every request with no network, so a store's loads fail at once
/// rather than reaching Discord from a test.
private nonisolated final class OfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
