import Foundation
import WingcordCore

// MARK: - What macOS says is playing
//
// The bundled mediaremote-adapter (Packaging/MediaRemoteAdapter): `/usr/bin/perl`
// runs its script, the script loads its framework, and MediaRemote — which
// answers only Apple's own processes since macOS 15.4 — answers perl. One line
// of JSON per change: full payloads (`--no-diff`), 100 ms of debounce, and no
// artwork, whose bytes would only be thrown away (covers go out by address).
//
// Measured on 27.2 (docs/CLIPS-PRESENCE.md, 0.3): 0.0–0.1 % CPU at rest,
// ~5.6 MB. It runs only while Now Playing is shared.

@MainActor
final class NowPlayingMonitor {

    /// What plays now — nil for nothing, or before the first line.
    private(set) var current: NowPlayingSnapshot?
    var onChange: ((NowPlayingSnapshot?) -> Void)?

    private var process: Process?
    private var reader: Task<Void, Never>?
    private var restart: Task<Void, Never>?
    private var isOn = false
    /// Exits in a row without a line read — the backoff's exponent.
    private var failures = 0

    var isRunning: Bool { isOn }

    func start() {
        guard !isOn else { return }
        isOn = true
        failures = 0
        launch()
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        restart?.cancel()
        restart = nil
        end()
        received(nil)
    }

    private func launch() {
        guard isOn else { return }
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let framework = Bundle.main.privateFrameworksURL?.appending(path: "MediaRemoteAdapter.framework"),
              FileManager.default.fileExists(atPath: framework.path(percentEncoded: false))
        else {
            // A bare `swift run` has no bundle to carry them — the app scripts do.
            Self.trace("adapter missing from the bundle; Now Playing is off")
            return
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/perl")
        process.arguments = [
            script.path(percentEncoded: false), framework.path(percentEncoded: false),
            "stream", "--no-diff", "--debounce=100", "--no-artwork",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Self.trace("adapter failed to start: \(error.localizedDescription)")
            scheduleRestart()
            return
        }
        self.process = process
        let lines = output.fileHandleForReading.bytes.lines
        reader = Task { [weak self] in
            var sawLine = false
            do {
                for try await line in lines {
                    guard let self, !Task.isCancelled else { return }
                    guard let update = NowPlayingStream.decode(Data(line.utf8)) else { continue }
                    sawLine = true
                    switch update {
                    case .playing(let snapshot): received(snapshot)
                    case .nothing: received(nil)
                    }
                }
            } catch {
                Self.trace("adapter output failed: \(error.localizedDescription)")
            }
            // The pipe closed: the process is gone.
            guard let self, !Task.isCancelled else { return }
            exited(afterReading: sawLine)
        }
    }

    private func received(_ snapshot: NowPlayingSnapshot?) {
        guard snapshot != current else { return }
        current = snapshot
        onChange?(snapshot)
    }

    /// An exit nobody asked for: tried again after 1, 2, 4… seconds, at most a
    /// minute apart — a run that read anything starts the count again.
    private func exited(afterReading sawLine: Bool) {
        end()
        received(nil)
        guard isOn else { return }
        if sawLine { failures = 0 }
        Self.trace("adapter exited (\(failures + 1) in a row)")
        scheduleRestart()
    }

    private func scheduleRestart() {
        failures += 1
        let delay = min(60, 1 << min(failures - 1, 6))
        restart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, isOn else { return }
            launch()
        }
    }

    private func end() {
        reader?.cancel()
        reader = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    nonisolated static func trace(_ message: @autoclosure () -> String) {
        SessionController.trace("now playing: \(message())")
    }
}
