import Foundation
import WingcordCore

/// The stages of a drag across a voice note's bars.
nonisolated enum VoiceNoteScrub {
    case began, moved
}

/// What a voice message is called, wherever one's shown without its bars.
nonisolated enum VoiceNoteWords {
    /// In a preview line: the DM list, a reply bar, a notification, the inbox.
    static let preview = MessageReference.voiceMessageExcerpt
    /// The mark beside it.
    static let symbol = "mic.fill"

    /// What VoiceOver reads.
    static func spoken(seconds: Double) -> String {
        let whole = max(1, Int(seconds.rounded()))
        let minutes = whole / 60
        let rest = whole % 60
        var parts: [String] = []
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if rest > 0 || minutes == 0 { parts.append("\(rest) second\(rest == 1 ? "" : "s")") }
        return "\(preview), \(parts.joined(separator: " "))"
    }

    /// Whether a message is a voice note, however it's been decoded: the flag's Discord's
    /// own, and an attachment with a waveform on it is what a client without the flag
    /// has to go on.
    static func isVoiceNote(_ message: Message) -> Bool {
        message.flags.contains(.isVoiceMessage)
            || message.attachments.contains { $0.waveform != nil && ($0.contentType?.hasPrefix("audio/") ?? false) }
    }
}
