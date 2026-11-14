import AppKit
import Observation
import SwiftUI
import WingcordCore

/// Where the running copy is, as far as updating it goes (docs/UPDATES.md D9).
///
/// **Sparkle replaces the app where it stands**, so a copy it can't write over
/// never updates — and says nothing about it. Two places look fine to the reader
/// and aren't: the disk image Wingcord came on, and the read-only copy macOS runs
/// instead of an app opened straight from where it was downloaded ("app
/// translocation"). Downloads itself can be written to, but it's the folder
/// people clear out.
nonisolated enum InstallLocation: Equatable {
    /// /Applications or ~/Applications.
    case applications
    /// Some other folder it can be updated in, such as a build folder.
    case elsewhere
    /// ~/Downloads: it updates, but Downloads gets emptied.
    case downloads
    /// Its disk image, which is read-only.
    case diskImage
    /// The read-only copy macOS runs of an app opened where it was downloaded.
    case translocated

    /// Worth asking to move.
    var asksToMove: Bool {
        switch self {
        case .applications, .elsewhere: false
        case .downloads, .diskImage, .translocated: true
        }
    }

    /// Sparkle can replace it where it stands.
    var canUpdate: Bool {
        switch self {
        case .applications, .elsewhere, .downloads: true
        case .diskImage, .translocated: false
        }
    }

    static func of(bundlePath: String, home: String, volumeIsReadOnly: Bool) -> InstallLocation {
        // First: a translocated copy sits on a read-only mount of its own.
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if volumeIsReadOnly { return .diskImage }
        if bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/") {
            return .applications
        }
        if bundlePath.hasPrefix(home + "/Downloads/") { return .downloads }
        return .elsewhere
    }

    /// This copy's.
    static var current: InstallLocation {
        let bundle = Bundle.main.bundleURL
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return of(
            bundlePath: bundle.path,
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            volumeIsReadOnly: readOnly
        )
    }
}

/// Offers to move a release to Applications when it runs from somewhere it
/// can't be kept up to date — once, two seconds after launch, and again from
/// Settings ▸ About whenever it's still there.
@Observable
final class MoveToApplications {
    static let shared = MoveToApplications()

    /// The question is up.
    var isOffered = false
    private(set) var isMoving = false
    private(set) var failure: String?

    /// Where this copy runs, read once: it can't change under a running app.
    let location: InstallLocation

    /// Only a release asks: a build without a feed doesn't update, wherever it is.
    var appliesHere: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String && location.asksToMove
    }

    private static let declinedKey = "updates.declinedMoveToApplications"

    private init() {
        location = InstallLocation.current
    }

    /// The launch's question, unless it was answered Not Now before.
    func offerAtLaunch() {
        guard appliesHere, !UserDefaults.standard.bool(forKey: Self.declinedKey) else { return }
        isOffered = true
    }

    func decline() {
        isOffered = false
        UserDefaults.standard.set(true, forKey: Self.declinedKey)
    }

    /// Copies the app into Applications, puts the downloaded copy in the Trash
    /// (a disk image can't be written to, so that one stays), and relaunches from
    /// the new place once this copy has quit.
    func move() {
        guard !isMoving else { return }
        isMoving = true
        failure = nil
        let source = Bundle.main.bundleURL
        let location = self.location
        Task.detached(priority: .userInitiated) {
            do {
                let destination = try Self.copyIntoApplications(source, from: location)
                await MainActor.run { AppRelaunch.afterQuitting(destination) }
            } catch {
                await MainActor.run {
                    self.isMoving = false
                    self.failure = "Wingcord couldn't be moved: \(error.localizedDescription)"
                    Log.fault(.app, "updates: move to Applications failed: \(error)")
                }
            }
        }
    }

    /// The folder it goes to: /Applications when it can be written to, the
    /// reader's own Applications otherwise, as Finder would offer.
    nonisolated private static func applicationsFolder() throws -> URL {
        let system = URL(filePath: "/Applications", directoryHint: .isDirectory)
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        let own = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        return own
    }

    nonisolated private static func copyIntoApplications(_ source: URL, from location: InstallLocation) throws -> URL {
        let destination = try applicationsFolder().appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        // An older copy already there goes to the Trash, where it can be got back.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
        }
        // `ditto` keeps the bundle exactly as it was signed: symlinks, modes, the seal.
        try run("/usr/bin/ditto", [source.path, destination.path])
        // The download's quarantine stays behind: this copy was opened once already.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
        // The downloaded copy goes to the Trash; a translocated one is found by its
        // real path first. A running app's files stay readable once trashed.
        switch location {
        case .downloads:
            try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
        case .translocated:
            if let original = originalOfTranslocated(source) {
                try? FileManager.default.trashItem(at: original, resultingItemURL: nil)
            }
        case .applications, .elsewhere, .diskImage:
            break
        }
        return destination
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(tool) failed (\(process.terminationStatus))"])
        }
    }

    /// The real place of a translocated app, from the Security framework's
    /// `SecTranslocateCreateOriginalPathForURL` — not in the SDK's headers, so
    /// looked up at run time; without it the download stays where it is.
    nonisolated private static func originalOfTranslocated(_ url: URL) -> URL? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL")
        else { return nil }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(symbol, to: Original.self)
        return original(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}

// MARK: - The question

struct MoveToApplicationsPrompt: View {
    var location: InstallLocation
    var answer: (_ move: Bool) -> Void

    var body: some View {
        ModalAlert(
            hero: .symbol("arrow.down.app", tint: Palette.accent),
            title: "Move Wingcord to Applications?",
            message: Text(message),
            actions: [
                .cancel("Not Now") { answer(false) },
                .act("Move to Applications", symbol: "folder") { answer(true) },
            ]
        )
    }

    private var message: String {
        let place = location == .diskImage
            ? "Wingcord is running from its disk image, where it can't update itself."
            : "Wingcord is running from where it was downloaded, where macOS won't let it update itself."
        return place + " In Applications it stays up to date, and it opens again there in a moment."
    }
}

struct MoveToApplicationsPresenter: ViewModifier {
    @State private var mover = MoveToApplications.shared

    func body(content: Content) -> some View {
        content
            .modal(isPresented: $mover.isOffered, style: .alert) {
                MoveToApplicationsPrompt(location: mover.location) { move in
                    if move {
                        mover.isOffered = false
                        mover.move()
                    } else {
                        mover.decline()
                    }
                }
            }
            .task {
                // Once the window is up behind it, as the after-crash question waits.
                try? await Task.sleep(for: .seconds(2))
                mover.offerAtLaunch()
            }
    }
}

extension View {
    /// Applied once, at the window root, beside `presentsBugReport`.
    func offersMoveToApplications() -> some View {
        modifier(MoveToApplicationsPresenter())
    }
}
