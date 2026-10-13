import Foundation
import WingcordCore
import WingcordNet

/// One person's entry, as a pending write is keyed.
struct AudioContextKey: Hashable {
    var context: AudioContextSettings.Context
    var userID: UserID
}

extension SessionController {

    /// The account's per-person sound settings, from READY or from another
    /// device — **keeping any entry this client has changed and not yet
    /// written**, so the echo of an older write cannot move a slider back
    /// under the reader's hand.
    func applyAudioContext(_ incoming: AudioContextSettings) {
        var merged = incoming
        for change in pendingAudioContext.values {
            merged[change.context][change.userID] = change.entry
        }
        model.audioContext = merged
        voice.applyAudioContext()
    }

    /// Writes one person's setting two seconds after the last change —
    /// Discord's own delay for this write — so a dragged slider is one write.
    func scheduleAudioContextWrite(_ change: AudioContextProto.Change) {
        pendingAudioContext[AudioContextKey(context: change.context, userID: change.userID)] = change
        audioContextWrite?.cancel()
        audioContextWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            let changes = Array(pendingAudioContext.values)
            pendingAudioContext.removeAll()
            do {
                try await rest.setAudioContext(changes)
            } catch {
                Self.trace("audio settings write failed: \(Self.describe(error))")
            }
        }
    }
}
