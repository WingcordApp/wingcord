import SwiftUI
import WingcordCore

// MARK: - A call's items in a person's menu
//
// Discord adds the same rows to whichever menu a person in the reader's call
// was right-clicked in — a server's person menu, or a direct message's — so
// they are written once, here (its modules 972432 and 198229, and the call's
// layout item).
//
// **No material of their own**: they are rows inside a flyout whose popover
// supplies the glass — `INVARIANTS.md` §4.9.

/// Discord's User Volume and, while the reader watches them, Stream Volume —
/// on Discord's slider and synced with the account.
struct CallVolumeItems: View {
    var userID: UserID

    @Environment(AppModel.self) private var model

    var body: some View {
        CallVolumeRow(
            title: "User Volume",
            gain: Binding(
                get: { model.audioContext.volume(of: userID, in: .user) },
                set: { model.setVolume($0, of: userID, in: .user) }
            ),
            maximum: 2
        )
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.tight)
        if model.watchedStreamUserID == userID {
            CallVolumeRow(
                title: "Stream Volume",
                gain: Binding(
                    get: { model.audioContext.volume(of: userID, in: .stream) },
                    set: { model.setVolume($0, of: userID, in: .stream) }
                ),
                maximum: 2
            )
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.tight)
        }
    }
}

/// Discord's switches for somebody in the call: Mute, Mute Soundboard and
/// Disable Video — or, for the reader, their own Mute and Deafen.
struct CallSwitchItems: View {
    var userID: UserID

    @Environment(AppModel.self) private var model

    var body: some View {
        if userID == model.currentUserID {
            FlyoutRow(title: "Mute", symbolName: "mic.slash", accessory: .checkbox(model.isSelfMuted)) {
                model.toggleVoiceMute()
            }
            FlyoutRow(title: "Deafen", symbolName: "headphones", accessory: .checkbox(model.isSelfDeafened)) {
                model.toggleVoiceDeafen()
            }
            // Discord's `change-video-background`, which says Preview Camera
            // while the camera is off.
            if !model.isCameraOn {
                FlyoutRow(title: "Preview Camera", symbolName: "eye") { model.previewCamera() }
            }
        } else {
            FlyoutRow(
                title: "Mute", symbolName: "speaker.slash",
                accessory: .checkbox(model.audioContext.isMuted(userID))
            ) { model.toggleLocalMute(userID) }
            FlyoutRow(
                title: "Mute Soundboard", symbolName: "music.note.list",
                accessory: .checkbox(model.audioContext.users[userID]?.isSoundboardMuted ?? false)
            ) { model.toggleSoundboardMute(userID) }
            FlyoutRow(
                title: "Disable Video", symbolName: "video.slash",
                accessory: .checkbox(model.isVideoDisabled(userID))
            ) { model.toggleVideoDisabled(userID) }
        }
    }
}

/// The call's own layout, offered from a tile: Discord's Show Non-Video
/// Participants.
struct CallLayoutItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FlyoutRow(
            title: "Show Non-Video Participants",
            symbolName: "person.2",
            accessory: .checkbox(model.showsNonVideoParticipants)
        ) {
            model.showsNonVideoParticipants.toggle()
        }
    }
}
