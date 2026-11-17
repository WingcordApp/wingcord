import Foundation
import WingcordCore

/// What a call shows in the picture in picture while the reader is somewhere
/// else (docs/ACTIVITIES-CALLS-PICKER.md, decision 4; Alex, 2026-11-17: "add
/// more support for PiP including for screenshares and everywhere else where
/// discord has PiP"): the stream being watched, else the person in the
/// spotlight, else the first camera.
struct CallPictureInPictureContent: Equatable {
    var userID: UserID
    var name: String
    /// A screen share being watched, rather than a camera.
    var isStream: Bool
    var channelID: ChannelID
}

extension AppModel {

    /// The call's picture in picture, or nil while the call is on screen,
    /// nothing in it is moving, or a running activity already has the corner.
    var callPictureInPicture: CallPictureInPictureContent? {
        guard activityHost != .pictureInPicture, !isCallFullScreen, let call = voicePresentation else { return nil }
        let channelID = call.channelID
        switch workspacePresentation.primary {
        case .conversation(let shown) where shown == channelID: return nil
        case .voice(let shown) where shown == channelID: return nil
        case .stage(let shown) where shown == channelID: return nil
        default: break
        }
        // By the flags, not by frames: a tile nobody draws stops receiving,
        // and the picture in picture is what draws it again.
        let moving = call.participants.filter { !$0.isSelf && ($0.isWatched || $0.isCameraOn) }
        let pick = moving.first(where: \.isWatched)
            ?? call.spotlightUserID.flatMap { id in moving.first { $0.id == id } }
            ?? moving.first
        guard let pick else { return nil }
        return CallPictureInPictureContent(
            userID: pick.id, name: pick.displayName, isStream: pick.isWatched, channelID: channelID
        )
    }

    /// The picture in picture's Return: the call, where it lives.
    func returnToCall(_ channelID: ChannelID) {
        if channelIndex[channelID]?.guildID == nil {
            openDirectMessage(channelID)
        } else {
            selectChannel(channelID)
        }
    }
}
