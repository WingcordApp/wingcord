import AppKit
import Foundation
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// What a scroll costs the main thread, measured through the real coordinators
/// in a window: each step moves the viewport as one frame of a scroll would and
/// paints whatever that made dirty.
///
/// **Rows painted is the number that is asserted; milliseconds are printed.**
/// A count does not depend on the machine or on what else it is doing, so it
/// can fail a build; a time is what the count is for, and is written to
/// `WINGCORD_BENCH_OUT` when that is set so a run before a change and a run
/// after it can be laid side by side (docs/PERFORMANCE.md keeps them).
@MainActor
@Suite("Scroll paint cost", .serialized)
struct ScrollPaintBenchmarkTests {

    struct Result {
        var name: String
        var steps: Int
        var travel: CGFloat
        var rowsPainted: Int
        var passes: Int
        var totalMS: Double
        var worstMS: Double
        var over8: Int
        var over4: Int
        var worstSteps: [Double] = []
        /// The part of `totalMS` spent moving the viewport and in the
        /// coordinator's answer to it; the rest is paint.
        var moveMS = 0.0

        var line: String {
            String(
                format: "%@: %d steps, %.0f pt, rows painted %d in %d passes, total %.1f ms (move %.1f, paint %.1f), worst %.2f ms, >8.3ms %d, >4ms %d",
                name, steps, Double(travel), rowsPainted, passes, totalMS, moveMS, totalMS - moveMS, worstMS, over8, over4
            ) + ", ten worst " + worstSteps.map { String(format: "%.2f", $0) }.joined(separator: " ")
        }
    }

    static func record(_ result: Result) {
        print("BENCH " + result.line)
        guard let path = ProcessInfo.processInfo.environment["WINGCORD_BENCH_OUT"] else { return }
        let url = URL(fileURLWithPath: path)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + result.line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: The member list

    private static let names = [
        "Ada Lovelace", "grace_hopper", "Linus", "ＶＡＰＯＲ", "márton", "Zoë 🌙", "the_real_kernighan",
        "Björn Ironside", "田中太郎", "xX_dragon_Xx", "Marguerite de la Fontaine", "q",
    ]
    /// A few faces on disk, decoded into the store before the scroll, so a row
    /// paints a picture through its clip as a real one does rather than a
    /// monogram.
    private static let faces: [URL] = (0..<6).map {
        URL.temporaryDirectory.appending(path: "wingcord-bench-face-\($0).png")
    }

    private static func loadFaces() async {
        for (index, url) in faces.enumerated() {
            let side = 128
            guard let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            context.setFillColor(CGColor(red: CGFloat(index) / 6, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 32, y: 32, width: 64, height: 64))
            guard let image = context.makeImage() else { continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            for size in [64, 80] {
                _ = await ImageStore.shared.image(for: ImageStore.Key(url: url, maximumPixelSize: size))
            }
        }
    }

    private static let games = ["Escape from Tarkov", "Baldur's Gate 3", "Factorio", "Counter-Strike 2", "Hades II"]

    private func entry(_ id: UInt64) -> MemberEntry {
        var entry = MemberEntry(
            userID: UserID(rawValue: id),
            name: Self.names[Int(id) % Self.names.count] + " \(id)",
            monogram: "M",
            status: id % 5 == 0 ? .idle : .online,
            isOnMobile: id % 7 == 0,
            isBot: id % 23 == 0
        )
        // Three rows in five say what they are doing, as a busy server's do.
        if id % 5 < 3 {
            entry.line = MemberRowLine(
                glyph: .game,
                text: Self.games[Int(id) % Self.games.count],
                since: Date(timeIntervalSinceNow: -Double(id % 9) * 1_200),
                joiner: " · ",
                isLive: true,
                spoken: "Playing"
            )
        }
        entry.avatarURL = Self.faces[Int(id) % Self.faces.count]
        if id % 4 == 0 { entry.tag = "WING" }
        if id % 3 == 0 { entry.colorValue = 0x5865F2 }
        return entry
    }

    private func roster(count: Int) -> Roster {
        var roster = Roster(identity: "1:everyone", sections: [], members: [:], rowCount: 0)
        let groups = 8
        let each = count / groups
        var index = 0
        for group in 0..<groups {
            roster.sections.append(RosterSection(
                key: .role(RoleID(rawValue: UInt64(group + 1))),
                title: "Role \(group + 1)", countText: "\(each)", index: index, count: each
            ))
            for row in 0..<each {
                roster.members[index + 1 + row] = entry(UInt64(group * each + row + 1))
            }
            index += each + 1
        }
        roster.rowCount = index
        return roster
    }

    private func mountedMemberList() -> (MemberListCoordinator, NSScrollView, NSWindow, MemberListCanvas?) {
        let coordinator = MemberListCoordinator()
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        let canvas = scrollView.documentView?.subviews.compactMap { $0 as? MemberListCanvas }.first
        return (coordinator, scrollView, window, canvas)
    }

    /// Scrolls `scrollView` by `step` points `steps` times, painting after each.
    private func scroll(
        _ scrollView: NSScrollView,
        steps: Int,
        step: CGFloat,
        paint: () -> Void,
        painted: () -> (rows: Int, passes: Int),
        name: String
    ) -> Result {
        let clock = ContinuousClock()
        var worst = 0.0
        var total = 0.0
        var over8 = 0
        var over4 = 0
        var all: [Double] = []
        var moveTotal = 0.0
        let before = painted()
        var y = scrollView.contentView.bounds.minY
        for _ in 0..<steps {
            y += step
            // The move and what the coordinator does about it, then the paint.
            let moved = clock.measure {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            let drew = clock.measure { paint() }
            let took = moved + drew
            moveTotal += Double(moved.components.attoseconds) / 1e15 + Double(moved.components.seconds) * 1_000
            let ms = Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1_000
            total += ms
            all.append(ms)
            worst = max(worst, ms)
            if ms > 8.3 { over8 += 1 }
            if ms > 4 { over4 += 1 }
        }
        let after = painted()
        return Result(
            name: name, steps: steps, travel: abs(CGFloat(steps) * step),
            rowsPainted: after.rows - before.rows, passes: after.passes - before.passes,
            totalMS: total, worstMS: worst, over8: over8, over4: over4,
            worstSteps: Array(all.sorted(by: >).prefix(10)),
            moveMS: moveTotal
        )
    }

    @Test("Member list: a scroll paints strips, never the whole canvas per tick")
    func memberListFling() async throws {
        await Self.loadFaces()
        let (coordinator, scrollView, window, found) = mountedMemberList()
        let canvas = try #require(found)
        coordinator.update(roster: roster(count: 4_000), presentationRevision: 0, topInset: 0)
        try await Task.sleep(for: .milliseconds(50))
        canvas.paintForMeasurement()

        print("BENCH-GEOMETRY clip \(scrollView.contentView.bounds) canvas \(canvas.frame) visible \(canvas.visibleRect) first paint rows \(canvas.paintedRowCount) tallest \(canvas.tallestPaint) prepared \(canvas.preparedContentRect)")
        // 30 points a frame is 3,600 points a second on a 120 Hz panel: a fling.
        let fling = scroll(
            scrollView, steps: 600, step: 30,
            paint: { canvas.paintForMeasurement() },
            painted: { (canvas.paintedRowCount, canvas.paintPassCount) },
            name: "member-list fling 30pt"
        )
        Self.record(fling)
        print("BENCH-GEOMETRY after fling: tallest \(canvas.tallestPaint) canvas \(canvas.frame) prepared \(canvas.preparedContentRect)")
        // 8 points a frame is a reading scroll.
        let reading = scroll(
            scrollView, steps: 600, step: 8,
            paint: { canvas.paintForMeasurement() },
            painted: { (canvas.paintedRowCount, canvas.paintPassCount) },
            name: "member-list reading 8pt"
        )
        Self.record(reading)

        // **A guard against painting the whole canvas per tick**, which is the
        // regression this would catch: nineteen rows a pass, thirty times the
        // rows revealed. As measured, AppKit asks for the newly exposed strip
        // each tick and the visible rows once per re-anchor, which comes to
        // five or six times the rows revealed in a fling and about ten in a
        // reading scroll — rows crossing an edge are painted once per strip.
        let revealed = fling.travel / MemberRowGeometry.rowHeight
        #expect(CGFloat(fling.rowsPainted) < revealed * 8)
        let revealedReading = reading.travel / MemberRowGeometry.rowHeight
        #expect(CGFloat(reading.rowsPainted) < revealedReading * 14)
        withExtendedLifetime((coordinator, window)) {}
    }

    // MARK: The transcript

    private let channel = ChannelID(rawValue: 7)

    private static let lines = [
        "ok",
        "did anyone else see the patch notes? they moved the whole inventory system around again",
        "I think the real problem is that the cache is keyed on a counter that moves for everybody, so every row is laid out again whenever anyone anywhere changes their name. That is a lot of work for nothing, and it shows up as a freeze when you scroll.",
        "lol",
        "https://example.com/some/long/path/to/an/article-about-things",
        "**bold claim** but I'd want to see a measurement first, `drawText` is not obviously slow",
        "> quoted line\nand the answer to it, which runs on for a little while so that it wraps onto a second line in a normal window",
        "😀 🎉 nice",
    ]

    private func messages(_ ids: ClosedRange<UInt64>) -> [Message] {
        ids.map { id in
            let milliseconds = (1_700_000_000 + id * 45) * 1000
            return Message(
                id: MessageID(rawValue: (milliseconds << 22) | id),
                channelID: channel,
                // Runs of a few messages by each of five people.
                authorID: UserID(rawValue: 10 + (id / 3) % 5),
                content: Self.lines[Int(id) % Self.lines.count]
            )
        }
    }

    @Test("Transcript: what a scroll costs")
    func transcriptFling() throws {
        let model = AppModel()
        for author in 10..<15 as Range<UInt64> {
            model.users[UserID(rawValue: author)] = User(id: UserID(rawValue: author), username: "author\(author)")
        }
        let coordinator = TimelineCoordinator(model: model)
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        coordinator.update(
            channelID: channel,
            items: TimelineReducer.rows(messages: messages(1...900), hasMoreHistory: false),
            presentationRevision: 0,
            activityAccents: [:],
            activityInviteStatuses: [:], uploadProgress: [:],
            topInset: 0,
            bottomInset: 0,
            jump: nil,
            reachesPresent: true,
            present: nil,
            flight: nil,
            scroll: TranscriptScrollState(),
            topics: [],
            summaries: [],
            selectedSummary: nil,
            cardRevision: 0,
            playingPreview: nil,
            isCovered: false,
            bookmarks: [],
            canSuperReact: false,
            canAddReactions: true,
            hidesMedia: false,
            listenAlongCards: [:],
            stageInvitations: []
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let canvas = try #require(
            scrollView.documentView?.subviews.compactMap { $0 as? TimelineCanvasView }.first
        )
        canvas.paintForMeasurement()
        #expect(canvas.contentHeight > 20_000, "the page is long enough to fling through")

        // A transcript opens at its foot, so the reader travels up.
        let fling = scroll(
            scrollView, steps: 500, step: -30,
            paint: { canvas.paintForMeasurement() },
            painted: { (canvas.paintedRowCount, canvas.paintPassCount) },
            name: "transcript fling 30pt"
        )
        Self.record(fling)
        let reading = scroll(
            scrollView, steps: 500, step: -8,
            paint: { canvas.paintForMeasurement() },
            painted: { (canvas.paintedRowCount, canvas.paintPassCount) },
            name: "transcript reading 8pt"
        )
        Self.record(reading)
        withExtendedLifetime((model, coordinator, window)) {}
    }

    // MARK: The channel list and the server rail (SwiftUI)

    /// The first scroll view under `view`, depth first.
    private func scrollView(in view: NSView) -> NSScrollView? {
        if let found = view as? NSScrollView { return found }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    private func serverModel(channels: Int, categories: Int) -> (AppModel, GuildID) {
        let model = AppModel()
        let reader = UserID(rawValue: 1)
        let guildID = GuildID(rawValue: 100)
        model.currentUserID = reader
        model.users[reader] = User(id: reader, username: "reader")
        model.guilds[guildID] = Guild(id: guildID, name: "Benchmark", ownerID: reader)
        var list: [Channel] = []
        let each = channels / categories
        var position = 0
        for category in 0..<categories {
            let categoryID = ChannelID(rawValue: UInt64(1_000 + category))
            list.append(Channel(
                id: categoryID, kind: .category, guildID: guildID,
                name: "Category \(category)", position: position
            ))
            position += 1
            for index in 0..<each {
                list.append(Channel(
                    id: ChannelID(rawValue: UInt64(10_000 + category * 1_000 + index)),
                    kind: index % 9 == 8 ? .voice : .text,
                    guildID: guildID,
                    name: "channel-\(category)-\(index)",
                    parentID: categoryID,
                    position: position
                ))
                position += 1
            }
        }
        var index = ChannelIndex()
        index.replaceChannels(list, inGuild: guildID)
        model.channelIndex = index
        model.members[guildID] = [reader: Member(userID: reader, roleIDs: [])]
        return (model, guildID)
    }

    @Test("Channel list: what a scroll through three hundred channels costs")
    func channelListScroll() async throws {
        let (model, guildID) = serverModel(channels: 300, categories: 12)
        let presentation = model.sidebarPresentation(for: guildID)
        #expect(presentation.rows.count > 300)
        let host = NSHostingView(rootView:
            ChannelSidebar(presentation: presentation, target: .none)
                .frame(width: 260, height: 900)
                .environment(model)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let found = try #require(scrollView(in: host), "the list's scroll view")
        let height = found.documentView?.frame.height ?? 0
        print("BENCH-GEOMETRY channel list document \(height) clip \(found.contentView.bounds)")
        #expect(height > 4_000, "the list is long enough to scroll")

        let clock = ContinuousClock()
        var all: [Double] = []
        var y = found.contentView.bounds.minY
        // 20 points a frame: a brisk scroll through the list.
        for _ in 0..<300 {
            y += 20
            let took = clock.measure {
                found.contentView.scroll(to: NSPoint(x: 0, y: y))
                found.reflectScrolledClipView(found.contentView)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
            all.append(Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1_000)
            // A turn of the run loop, as a frame gets: SwiftUI does its own
            // work for a list there.
            await Task.yield()
        }
        let sorted = all.sorted(by: >)
        Self.record(Result(
            name: "channel-list scroll 20pt", steps: all.count, travel: 6_000,
            rowsPainted: 0, passes: 0,
            totalMS: all.reduce(0, +), worstMS: sorted[0],
            over8: all.count { $0 > 8.3 }, over4: all.count { $0 > 4 },
            worstSteps: Array(sorted.prefix(10))
        ))
        withExtendedLifetime((model, window)) {}
    }
}
