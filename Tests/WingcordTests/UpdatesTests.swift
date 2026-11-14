import Foundation
import Testing
@testable import Wingcord

/// Updates (docs/UPDATES.md): how an update is named from its appcast item,
/// which notes the card draws, and where a copy can be updated from.
@Suite("Updates")
struct UpdatesTests {

    // MARK: Names

    /// The beta's name travels in the item's title, which the release command
    /// writes (D3); the version itself stays "1.0".
    @Test func nameComesFromTheTitle() {
        #expect(UpdateNaming.displayVersion(title: "Wingcord 1.0 Beta 2", shortVersion: "1.0", build: "2") == "1.0 Beta 2")
        #expect(UpdateNaming.displayVersion(title: "Wingcord 1.0", shortVersion: "1.0", build: "7") == "1.0")
        #expect(UpdateNaming.displayVersion(title: "Wingcord  1.1 RC 1 ", shortVersion: "1.1", build: "9") == "1.1 RC 1")
    }

    /// Any other title — or none — says what Sparkle's own window would.
    @Test func otherTitlesFallBackToVersionAndBuild() {
        #expect(UpdateNaming.displayVersion(title: nil, shortVersion: "1.0", build: "2") == "1.0 (2)")
        #expect(UpdateNaming.displayVersion(title: "1.0", shortVersion: "1.0", build: "2") == "1.0 (2)")
        #expect(UpdateNaming.displayVersion(title: "Wingcord ", shortVersion: "1.0", build: "3") == "1.0 (3)")
        #expect(UpdateNaming.displayVersion(title: "Wingcordless 2", shortVersion: "2.0", build: "4") == "2.0 (4)")
    }

    /// Markdown and plain text are drawn; HTML — Sparkle's default — and
    /// empty notes aren't.
    @Test func onlyTextNotesAreDrawn() {
        #expect(UpdateNaming.notes("### New\n- A thing", format: "markdown") == "### New\n- A thing")
        #expect(UpdateNaming.notes("Fixed a crash.", format: "plain-text") == "Fixed a crash.")
        #expect(UpdateNaming.notes("<ul><li>x</li></ul>", format: nil) == nil)
        #expect(UpdateNaming.notes("<ul><li>x</li></ul>", format: "html") == nil)
        #expect(UpdateNaming.notes("  \n ", format: "markdown") == nil)
        #expect(UpdateNaming.notes(nil, format: "markdown") == nil)
    }

    // MARK: Where it runs from (D9)

    private let home = "/Users/someone"

    private func location(_ path: String, readOnly: Bool = false) -> InstallLocation {
        InstallLocation.of(bundlePath: path, home: home, volumeIsReadOnly: readOnly)
    }

    @Test func applicationsFoldersAreHome() {
        #expect(location("/Applications/Wingcord.app") == .applications)
        #expect(location("/Users/someone/Applications/Wingcord.app") == .applications)
        #expect(!InstallLocation.applications.asksToMove)
        #expect(InstallLocation.applications.canUpdate)
    }

    /// A translocated copy sits on a read-only mount of its own, so it's
    /// recognised before the read-only test that means a disk image.
    @Test func translocationIsRecognisedFirst() {
        let path = "/private/var/folders/xy/abc/T/AppTranslocation/0A1B2C3D-0000-0000-0000-000000000000/d/Wingcord.app"
        #expect(location(path, readOnly: true) == .translocated)
        #expect(InstallLocation.translocated.asksToMove)
        #expect(!InstallLocation.translocated.canUpdate)
    }

    @Test func aDiskImageCantBeUpdated() {
        #expect(location("/Volumes/Wingcord/Wingcord.app", readOnly: true) == .diskImage)
        #expect(InstallLocation.diskImage.asksToMove)
        #expect(!InstallLocation.diskImage.canUpdate)
    }

    /// Downloads can be written to, so it updates — but it's the folder people
    /// empty, so it's still worth asking.
    @Test func downloadsUpdatesButAsks() {
        #expect(location("/Users/someone/Downloads/Wingcord.app") == .downloads)
        #expect(InstallLocation.downloads.asksToMove)
        #expect(InstallLocation.downloads.canUpdate)
    }

    /// A build folder, a copy on the Desktop: left alone.
    @Test func anywhereElseIsLeftAlone() {
        #expect(location("/Users/someone/Desktop/Wingcord-macOS/build/Wingcord.app") == .elsewhere)
        #expect(location("/Users/someone/DownloadsArchive/Wingcord.app") == .elsewhere)
        #expect(!InstallLocation.elsewhere.asksToMove)
    }
}
