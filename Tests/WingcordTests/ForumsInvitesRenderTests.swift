import AppKit
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// The forum row and the cards over the demo's own model, drawn offscreen: with
/// `WINGCORD_RENDER_DIR` set each is written there as a PNG to look at, and without it
/// they still lay out, which catches one that collapses. Glass doesn't composite
/// offscreen, so this is for where things are, not how they look.
@MainActor
@Suite("Forums and invites, drawn offscreen", .serialized)
struct ForumsInvitesRenderTests {

    private func demoModel() throws -> (AppModel, ChannelID) {
        let model = AppModel()
        DemoFixtures.populate(model)
        let guildID = try #require(model.selectedGuildID)
        let forumID = try #require(model.channelIndex.channelIDs(inGuild: guildID).first {
            model.channelIndex[$0]?.name == "bug-reports"
        })
        return (model, forumID)
    }

    /// Every view of a kind under a view.
    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        for subview in view.subviews {
            if let match = subview as? T { found.append(match) }
            found += descendants(of: type, in: subview)
        }
        return found
    }

    /// Lays a view out and lets what it asked for on the next turn happen.
    private func host<Content: View>(_ view: Content, size: CGSize) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func write(_ host: NSView, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"],
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    // MARK: New Post

    /// **`ViewThatFits` lays out every candidate**, and a form whose candidates each
    /// hold a composer has two text views bound to one draft: the caret and the words
    /// could be in the one not being shown.
    @Test("The card holds one composer, however it fits", arguments: [900.0, 420.0])
    func oneComposer(height: CGFloat) throws {
        let (model, forumID) = try demoModel()
        model.beginForumPost(in: forumID)
        let card = host(NewPostSheet(channelID: forumID).environment(model), size: CGSize(width: 640, height: height))
        #expect(descendants(of: MarkdownTextView.self, in: card).count == 1)
        try write(card, named: "new-post-\(Int(height))")
    }

    // MARK: The window

    private func window(of model: AppModel, width: CGFloat, height: CGFloat = 760) -> NSHostingView<some View> {
        host(RootView().environment(model), size: CGSize(width: width, height: height))
    }

    @Test("The forum's row at every width the window goes to", arguments: [880.0, 1_100.0, 1_300.0, 1_512.0])
    func row(width: CGFloat) throws {
        let (model, forumID) = try demoModel()
        model.selectChannel(forumID)
        let shell = window(of: model, width: width)
        try write(shell, named: "forum-\(Int(width))")
    }

    @Test("With the sidebar away, and a post open beside the board")
    func sidebarAway() async throws {
        try await withAppSettings(\.isSidebarShown) { settings in
            let (model, forumID) = try demoModel()
            model.selectChannel(forumID)
            settings.isSidebarShown = false
            try write(window(of: model, width: 1_100), named: "forum-no-sidebar")

            let post = try #require(model.forumPresentation(for: forumID).posts.dropFirst().first)
            settings.isSidebarShown = true
            model.selectedThreadID = post.id
            try write(window(of: model, width: 1_300), named: "forum-with-post")
            try write(window(of: model, width: 880), named: "forum-with-post-narrow")
        }
    }

    @Test("A media channel, and a gallery beside a post")
    func gallery() throws {
        let (model, forumID) = try demoModel()
        let guildID = try #require(model.selectedGuildID)
        let mediaID = try #require(model.channelIndex.channelIDs(inGuild: guildID).first {
            model.channelIndex[$0]?.name == "voxy-screenshot-contest"
        })
        model.selectChannel(mediaID)
        try write(window(of: model, width: 1_100), named: "media-1100")

        model.selectChannel(forumID)
        var query = model.forumBoard(for: forumID).query
        query.layout = .gallery
        model.setForumQuery(query, in: forumID)
        try write(window(of: model, width: 880), named: "gallery-880")
    }

    // MARK: The invite sheet

    @Test("The sheet in each of its forms", arguments: ["demo-craft", "demo-plain", "demo-group", "demo-friend", "demo-dead"])
    func sheet(code: String) throws {
        let (model, _) = try demoModel()
        model.openInvite(key: code)
        let state = try #require(model.inviteSheet)
        let sheet = host(
            InviteAcceptSheet(
                state: state,
                presentation: model.inviteSheetPresentation(state),
                setNickname: { _ in },
                setAllowsDirectMessages: { _ in },
                setShowsActivity: { _ in },
                accept: {},
                openNitro: {},
                dismiss: {}
            )
            .frame(maxWidth: 1_040)
            .background(Palette.surface)
            .environment(model),
            size: CGSize(width: code == "demo-craft" ? 1_040 : 560, height: 620)
        )
        try write(sheet, named: "invite-\(code)")
    }
}
