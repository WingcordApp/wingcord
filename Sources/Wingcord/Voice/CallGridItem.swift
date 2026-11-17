import WingcordCore

/// One slot in a call's grid: a person, or the activity's Join tile.
enum CallGridItem: Identifiable {
    case person(VoiceParticipant)
    case activity(CallActivityPresentation)

    var id: String {
        switch self {
        case .person(let participant): "u\(participant.id.rawValue)"
        case .activity(let activity): "a\(activity.applicationID.rawValue)"
        }
    }
}
