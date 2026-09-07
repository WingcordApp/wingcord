import SwiftUI
import WingcordNet

/// The bridge between a request Discord refused and somebody who can answer it.
///
/// `DiscordREST` awaits `solve(_:)` from **inside** the request it is retrying,
/// so this has one job: put the challenge on screen and resume that request with
/// whatever comes back. `nil` means nobody answered — a cancelled window, a
/// dismissed one, or no surface mounted to show one — and the request then fails
/// with Discord's own rejection rather than with something invented here.
///
/// **A queue rather than a single slot.** Two writes can be in flight from two
/// surfaces, and a second challenge arriving while the first is up must not be
/// dropped: dropping it resumes nothing, and the request waiting on it hangs for
/// ever behind a spinner. The queue is bounded by the number of in-flight
/// writes, which is one in every real case.
@MainActor
@Observable
final class CaptchaSolver {

    /// The challenge on screen, shaped for `.sheet(item:)`.
    struct Pending: Identifiable, Equatable {
        let id: UUID
        let challenge: CaptchaChallenge
    }

    private struct Waiter {
        let id: UUID
        let challenge: CaptchaChallenge
        let resume: (CaptchaSolution?) -> Void
    }

    private var queue: [Waiter] = []

    /// Surfaces that can currently present, outermost first.
    ///
    /// **macOS will not present a sheet from a view that a sheet already
    /// covers.** So the Join a Server sheet registers on top of the window root,
    /// and the innermost host is the one that presents — which is the only one
    /// that can. Exactly one host is ever active, so two can never race to show
    /// the same challenge.
    private var hosts: [UUID] = []

    var pending: Pending? {
        queue.first.map { Pending(id: $0.id, challenge: $0.challenge) }
    }

    var activeHost: UUID? { hosts.last }

    // MARK: Solving

    /// Presents `challenge` and waits.
    ///
    /// Called from the REST actor, which is not the main actor — hence the hop
    /// this method's isolation performs rather than one at the call site.
    func solve(_ challenge: CaptchaChallenge) async -> CaptchaSolution? {
        // Nothing mounted to present it. Answering immediately is what turns
        // this into the plain rejection the caller already knows how to report,
        // rather than a request parked on a window that will never open.
        guard !hosts.isEmpty else { return nil }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.append(
                    Waiter(id: id, challenge: challenge) { continuation.resume(returning: $0) }
                )
                // Cancelled between entering this function and parking here: the
                // handler below has already run and found nothing to cancel, so
                // this is the only place left that can unblock it.
                if Task.isCancelled { resolve(id, with: nil) }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(id, with: nil) }
        }
    }

    /// Resumes one parked request. Idempotent: a waiter already resolved is no
    /// longer in the queue, and resolving it again does nothing.
    ///
    /// That matters more than it looks. The sheet resolves on its own dismissal
    /// *and* on the solved callback, and the binding resolves when the sheet is
    /// closed from the window — three paths to one waiter, of which exactly one
    /// must reach the continuation.
    func resolve(_ id: UUID, with solution: CaptchaSolution?) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).resume(solution)
    }

    // MARK: Hosts

    func register(_ id: UUID) {
        guard !hosts.contains(id) else { return }
        hosts.append(id)
    }

    func deregister(_ id: UUID) {
        hosts.removeAll { $0 == id }
        // **Nothing left that can present.** Every parked request would wait on
        // a window with nowhere to open — a join spinning for ever, which is the
        // one failure this object exists to make impossible. Resolving them
        // unsolved reports Discord's own rejection instead.
        guard hosts.isEmpty, !queue.isEmpty else { return }
        let stranded = queue
        queue.removeAll()
        for waiter in stranded { waiter.resume(nil) }
    }
}

/// The `Sendable` face the REST actor holds.
///
/// **A separate value rather than a conformance on the solver**, because the
/// solver is `@MainActor` and the actor storing it is not: this hops, carries no
/// state of its own, and keeps the isolation boundary at one line that can be
/// read.
struct CaptchaBridge: CaptchaSolving {
    let solver: @MainActor () -> CaptchaSolver?

    func solve(_ challenge: CaptchaChallenge) async -> CaptchaSolution? {
        await MainActor.run { solver() }?.solve(challenge) ?? nil
    }
}

// MARK: - Hosting

extension View {
    /// Lets this surface present a challenge raised by any request made while it
    /// is on screen.
    ///
    /// **One at the window root, and one on every sheet that can raise a write.**
    /// A view covered by a sheet cannot present anything, so the root's host
    /// alone would silently fail to show a challenge raised from inside Join a
    /// Server — which is the one place that reliably raises them.
    func captchaHost() -> some View {
        modifier(CaptchaHostModifier())
    }
}

private struct CaptchaHostModifier: ViewModifier {
    /// **Optional on purpose.** A non-optional `@Environment(Object.self)` traps
    /// the instant it is read with none in scope, and this modifier is meant to
    /// be applied liberally. No solver means no host, which means
    /// `CaptchaSolver.solve` answers immediately and the request reports
    /// Discord's own rejection. A missing captcha window must never be a crash.
    @Environment(CaptchaSolver.self) private var solver: CaptchaSolver?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        // Read once, here, rather than inside the binding's getter — so a
        // dismissal arriving after the next challenge has taken its place
        // resolves the one it belongs to and not the new one.
        let mine = solver?.activeHost == id ? solver?.pending : nil

        return content
            .onAppear { solver?.register(id) }
            .onDisappear { solver?.deregister(id) }
            .sheet(
                item: Binding(
                    get: { mine },
                    set: { if $0 == nil, let mine { solver?.resolve(mine.id, with: nil) } }
                )
            ) { pending in
                CaptchaSheet(challenge: pending.challenge) { solution in
                    solver?.resolve(pending.id, with: solution)
                }
                // The backstop. However this leaves the screen — solved,
                // cancelled, or torn off by its presenter going away — the
                // request behind it is resumed. A missed path here is not a
                // cosmetic bug; it is a join that spins for ever.
                .onDisappear { solver?.resolve(pending.id, with: nil) }
            }
    }
}
