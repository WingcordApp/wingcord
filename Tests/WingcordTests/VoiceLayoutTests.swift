import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The tile grid's arithmetic.
///
/// **A grid that reshuffles is the most obvious defect a call surface can
/// have**, and "does it reshuffle" is not something that can be judged reliably
/// by looking at it. So the arrangement is a value, and the value is checked
/// against a table.
@Suite("Voice grid layout")
struct VoiceGridLayoutTests {

    private let wide = CGSize(width: 960, height: 540)
    private let tall = CGSize(width: 480, height: 900)

    @Test("One person fills the space")
    func oneFillsIt() {
        let layout = VoiceGridLayout.solve(count: 1, in: wide)
        #expect(layout.columns == 1)
        #expect(layout.rows == 1)
        #expect(layout.tileSize.width > 900)
    }

    /// The point of solving rather than guessing: four in a wide window belong
    /// in a shape that uses the width, and a fixed "nearest square" rule would
    /// put them in a 2×2 that wastes half of it.
    @Test("The arrangement chosen is the one that makes the tiles biggest")
    func picksTheBiggestTiles() {
        for count in 1...9 {
            let layout = VoiceGridLayout.solve(count: count, in: wide)
            let chosen = layout.tileSize.width * layout.tileSize.height
            for rows in 1...count {
                let columns = Int((Double(count) / Double(rows)).rounded(.up))
                let width = (wide.width - VoiceGridLayout.spacing * CGFloat(columns - 1))
                    / CGFloat(columns)
                let height = (wide.height - VoiceGridLayout.spacing * CGFloat(rows - 1))
                    / CGFloat(rows)
                let side = min(width, height * VoiceGridLayout.aspect)
                let area = side * (side / VoiceGridLayout.aspect)
                #expect(chosen >= area - 0.5, "\(count) people: \(rows) rows beats the choice")
            }
        }
    }

    @Test("A tall window stacks where a wide one spreads")
    func shapeFollowsTheWindow() {
        let across = VoiceGridLayout.solve(count: 3, in: wide)
        let down = VoiceGridLayout.solve(count: 3, in: tall)
        #expect(across.columns >= down.columns)
        #expect(down.rows >= across.rows)
    }

    @Test("Every tile has a row, and no row overflows")
    func rowsCoverEveryone() {
        for count in 1...12 {
            let layout = VoiceGridLayout.solve(count: count, in: wide)
            let ranges = layout.rowRanges(count: count)
            #expect(ranges.reduce(0) { $0 + $1.count } == count)
            #expect(ranges.allSatisfy { $0.count <= layout.columns })
            #expect(ranges.first?.lowerBound == 0)
            #expect(ranges.last?.upperBound == count)
        }
    }

    @Test("Tiles keep one aspect whether or not anyone has a camera")
    func theAspectIsConstant() {
        for count in 1...8 {
            let layout = VoiceGridLayout.solve(count: count, in: wide)
            let ratio = layout.tileSize.width / layout.tileSize.height
            #expect(abs(ratio - VoiceGridLayout.aspect) < 0.001)
        }
    }

    @Test("Nothing to lay out is not a crash")
    func emptyIsSafe() {
        let layout = VoiceGridLayout.solve(count: 0, in: wide)
        #expect(layout.tileSize == .zero)
        #expect(layout.rowRanges(count: 0).isEmpty)
        #expect(VoiceGridLayout.solve(count: 4, in: .zero).tileSize == .zero)
    }

    /// The strip is along the bottom because a shared screen is wider than it is
    /// tall — the space left over by fitting one is a band under it, and a strip
    /// beside it would take width off the thing everybody is looking at.
    @Test("The spotlight keeps the stage and puts the rest underneath")
    func spotlightReservesAStrip() {
        let layout = VoiceSpotlightLayout.solve(others: 3, in: wide)
        #expect(layout.stage.width == wide.width)
        #expect(layout.strip.minY > layout.stage.maxY)
        #expect(layout.stage.height + layout.strip.height <= wide.height)
        #expect(layout.strip.height <= wide.height * 0.25 + 0.5)
    }

    @Test("One person alone on the stage takes all of it")
    func spotlightAloneFills() {
        let layout = VoiceSpotlightLayout.solve(others: 0, in: wide)
        #expect(layout.stage.size == wide)
        #expect(layout.strip == .zero)
    }
}

/// The connection, graded.
@Suite("Voice quality")
struct VoiceQualityTests {

    @Test("A path with FEC in it is good until loss and jitter both matter")
    func gradesFollowTheNumbers() {
        #expect(VoiceQuality(lossPercent: 0, jitterMilliseconds: 5, isConnected: true).grade == .good)
        #expect(VoiceQuality(lossPercent: 1, jitterMilliseconds: 20, isConnected: true).grade == .good)
        #expect(VoiceQuality(lossPercent: 3, jitterMilliseconds: 10, isConnected: true).grade == .fair)
        #expect(VoiceQuality(lossPercent: 0, jitterMilliseconds: 45, isConnected: true).grade == .fair)
        #expect(VoiceQuality(lossPercent: 8, jitterMilliseconds: 10, isConnected: true).grade == .poor)
        #expect(VoiceQuality(lossPercent: 0, jitterMilliseconds: 90, isConnected: true).grade == .poor)
    }

    /// Not yet connected is its own grade, never "good with no packets" — a
    /// connection that has not happened must not report itself as a healthy one.
    @Test("Not connected outranks every number")
    func connectingWins() {
        #expect(VoiceQuality(lossPercent: 0, jitterMilliseconds: 0, isConnected: false).grade
            == .connecting)
        #expect(VoiceQuality.idle.grade == .connecting)
    }
}

// MARK: - What a call says about who can hear it

/// The encryption line's own logic, which is the part that can be wrong without
/// looking wrong.
///
/// **A call that is not end-to-end encrypted must not read like one that is.**
/// That is the single claim this feature makes, and it is made in three places —
/// a glyph, a colour and a sentence — so all three are checked against the state
/// rather than against each other.
@Suite("Voice encryption indicator")
struct VoiceEncryptionIndicatorTests {
    @Test("Each state gets its own glyph, and none of them share one")
    func glyphsAreDistinct() {
        let states: [VoiceQuality.Encryption] = [
            .transportOnly, .establishing, .endToEnd(verificationCode: "0"),
        ]
        let symbols = states.map { state in
            VoiceQualityLine(
                quality: VoiceQuality(
                    lossPercent: 0, jitterMilliseconds: 0, isConnected: true,
                    encryption: state
                ),
                channelName: "General",
                guildName: nil
            ).encryptionSymbolForTesting
        }
        #expect(Set(symbols).count == states.count)
        // The open padlock is the one that matters: an absent glyph would read
        // as "nothing to report" when the thing to report is that the server
        // can hear the call.
        #expect(symbols[0] == "lock.open")
    }

    @Test("Only the end-to-end state claims to be end to end")
    func descriptionsAreHonest() {
        func description(_ state: VoiceQuality.Encryption) -> String {
            VoiceQualityLine(
                quality: VoiceQuality(
                    lossPercent: 0, jitterMilliseconds: 0, isConnected: true,
                    encryption: state
                ),
                channelName: "General",
                guildName: nil
            ).encryptionDescriptionForTesting
        }
        #expect(description(.transportOnly).contains("not end to end"))
        #expect(!description(.establishing).lowercased().hasPrefix("end-to-end encrypted"))
        #expect(description(.endToEnd(verificationCode: "1234567890"))
            .hasPrefix("End-to-end encrypted"))
    }

    /// Thirty digits in one run is a code nobody can read aloud without losing
    /// their place, which is the only thing the code is for.
    @Test("The verification code is grouped in fives for reading out")
    func codeIsGrouped() {
        let code = "090606058512110636351516066685"
        let line = VoiceQualityLine(
            quality: VoiceQuality(
                lossPercent: 0, jitterMilliseconds: 0, isConnected: true,
                encryption: .endToEnd(verificationCode: code)
            ),
            channelName: "General",
            guildName: nil
        )
        #expect(line.encryptionDescriptionForTesting
            .contains("09060 60585 12110 63635 15160 66685"))
    }
}

/// The encryption claim has to survive every other thing that touches the call's
/// quality, and a statistics tick arrives twice a second.
@Suite("Voice quality carries its encryption")
struct VoiceQualityEncryptionPersistenceTests {
    @Test("Updating loss and jitter does not reset what the call promised")
    func statisticsDoNotClearEncryption() {
        var quality = VoiceQuality(
            lossPercent: 0, jitterMilliseconds: 4, isConnected: true,
            encryption: .endToEnd(verificationCode: "1234567890")
        )
        // The shape the controller uses: mutate the two measured fields and
        // leave the rest alone. Rebuilding the struct instead is what silently
        // dropped the badge back to `.transportOnly`.
        quality.lossPercent = 7
        quality.jitterMilliseconds = 80
        #expect(quality.encryption == .endToEnd(verificationCode: "1234567890"))
        #expect(quality.grade == .poor)
    }

    /// A call that has ended must not still claim to be protected.
    @Test("The idle quality claims nothing")
    func idleClaimsNothing() {
        #expect(VoiceQuality.idle.encryption == .transportOnly)
        #expect(!VoiceQuality.idle.isConnected)
    }
}
