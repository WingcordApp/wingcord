import AppKit
import Foundation
import Network

/// Tells a call when its network path changed or the Mac woke up.
///
/// **Both leave a media socket talking to nothing.** The voice server's UDP
/// socket is bound to the interface the call started on; a switch from Wi-Fi to
/// Ethernet, a VPN coming up, or a sleep long enough for the server to forget
/// the session all leave the call silent until something notices. Discord's
/// client resets its connection when the network comes back; this does the
/// same for the call (docs/ACTIVITIES-CALLS-PICKER.md, decision 10).
@MainActor
final class CallNetworkWatch {
    private let monitor = NWPathMonitor()
    private var wakeObserver: (any NSObjectProtocol)?
    private var lastPath: String?
    private var pending: Task<Void, Never>?
    private let onChange: @MainActor (String) -> Void

    init(onChange: @escaping @MainActor (String) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = Self.signature(of: path)
            let isUsable = path.status == .satisfied
            Task { @MainActor [weak self] in self?.pathChanged(to: signature, isUsable: isUsable) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.wingcord.call-network"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle("The Mac woke from sleep") }
        }
    }

    func stop() {
        monitor.cancel()
        pending?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// The first path is the one the call started on; a later, different,
    /// usable one is a change worth reconnecting for.
    private func pathChanged(to signature: String, isUsable: Bool) {
        defer { if isUsable { lastPath = signature } }
        guard isUsable, let lastPath, lastPath != signature else { return }
        settle("The network changed")
    }

    /// Waits a second for the change to finish (an interface comes up in a few
    /// steps), then reports once.
    private func settle(_ reason: String) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.onChange(reason)
        }
    }

    /// Which interface carries the traffic: the first one the path prefers.
    nonisolated private static func signature(of path: NWPath) -> String {
        path.availableInterfaces.first.map { "\($0.name)/\($0.type)" } ?? "none"
    }
}
