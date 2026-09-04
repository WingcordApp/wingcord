import AppKit
import CoreGraphics
import Foundation
import WingcordCore

/// A poll, laid out.
///
/// **The bar is part of the answer row, not a track behind it.** Discord draws a
/// filled region growing across the row itself, and that is the right shape: the
/// row *is* the quantity, so a separate progress track under a label would be
/// two objects describing one number.
///
/// **Results are hidden until there is a reason to show them** — after the
/// reader votes, or after the poll closes. Before that, bars would tell everyone
/// how to vote, which is the whole reason the answer is hidden at all.
nonisolated struct PollSlot: Sendable {
    var rect: CGRect
    var question: TimelineTextBlock
    var questionOrigin: CGPoint
    var answers: [PollAnswerSlot]
    var footer: TimelineTextBlock?
    var footerOrigin: CGPoint
    /// Whether a click on an answer casts a vote.
    var isVotable: Bool
}

nonisolated struct PollAnswerSlot: Sendable {
    var rect: CGRect
    /// How far the fill runs across `rect`, 0...1. Zero while results are hidden.
    var share: Double
    var answerID: Int
    var label: TimelineTextBlock
    var labelOrigin: CGPoint
    var emoji: EmojiRef?
    var emojiRect: CGRect
    /// "10 votes  83%" — nil while results are hidden.
    var tally: TimelineTextBlock?
    var tallyOrigin: CGPoint
    var isMine: Bool
    var isWinner: Bool
}

nonisolated enum PollLayoutEngine {

    static let padding: CGFloat = 14
    static let answerHeight: CGFloat = 38
    static let answerGap: CGFloat = 6
    static let answerCorner: CGFloat = 8
    static let emojiSide: CGFloat = 22
    static let inset: CGFloat = 12

    /// A poll's own runs are **plain text, not markdown**, which is why this
    /// takes no parser and no mention table: Discord does not render markdown in
    /// a poll question or an answer, and parsing one anyway would turn a literal
    /// `*` in somebody's answer into emphasis nobody typed.
    static func layout(
        _ poll: Poll,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> PollSlot {
        let cardWidth = min(Metrics.embedMaxWidth, availableWidth)
        let contentX = origin.x + padding
        let contentWidth = max(60, cardWidth - padding * 2)
        var y = origin.y + padding

        let questionFont = NSFont.systemFont(
            ofSize: style.bodyFont.pointSize * 1.08, weight: .semibold
        )
        let question = block(
            poll.question,
            font: questionFont,
            color: style.primaryColor,
            width: contentWidth,
            style: style
        )
        let questionOrigin = CGPoint(x: contentX, y: y)
        y += question.size.height + padding

        let showsResults = poll.showsResults
        let winner = poll.winner
        var answers: [PollAnswerSlot] = []
        answers.reserveCapacity(poll.answers.count)

        for answer in poll.answers {
            let rect = CGRect(x: contentX, y: y, width: contentWidth, height: answerHeight)
            let hasEmoji = answer.emoji != nil
            let labelX = contentX + inset + (hasEmoji ? emojiSide + 8 : 0)
            // The tally is reserved before the label is laid out, so a long
            // answer wraps or truncates around it rather than running underneath.
            let tallyText = showsResults ? Self.tallyLabel(answer, in: poll) : nil
            let tallyWidth = tallyText.map {
                TimelineLayoutEngine.measure($0, font: style.metadataFont) + 10
            } ?? 0
            let labelWidth = max(20, rect.maxX - inset - tallyWidth - labelX)

            let label = block(
                answer.text,
                font: answer.isMine ? style.boldFont : style.bodyFont,
                color: style.primaryColor,
                width: labelWidth,
                style: style
            )
            var tally: TimelineTextBlock?
            var tallyOrigin = CGPoint.zero
            if let tallyText {
                let measured = block(
                    tallyText,
                    font: style.metadataFont,
                    color: style.secondaryColor,
                    width: max(20, tallyWidth),
                    style: style
                )
                tally = measured
                tallyOrigin = CGPoint(
                    x: rect.maxX - inset - measured.size.width,
                    y: rect.midY - measured.size.height / 2
                )
            }

            answers.append(PollAnswerSlot(
                rect: rect,
                share: showsResults ? poll.share(of: answer) : 0,
                answerID: answer.id,
                label: label,
                labelOrigin: CGPoint(x: labelX, y: rect.midY - label.size.height / 2),
                emoji: answer.emoji,
                emojiRect: CGRect(
                    x: contentX + inset,
                    y: rect.midY - emojiSide / 2,
                    width: emojiSide,
                    height: emojiSide
                ),
                tally: tally,
                tallyOrigin: tallyOrigin,
                isMine: answer.isMine,
                isWinner: answer.id == winner?.id
            ))
            y += answerHeight + answerGap
        }
        y -= answerGap

        let footerText = Self.footerLabel(poll)
        let footer = footerText.map {
            block(
                $0,
                font: style.metadataFont,
                color: style.tertiaryColor,
                width: contentWidth,
                style: style
            )
        }
        var footerOrigin = CGPoint.zero
        if let footer {
            y += padding - 2
            footerOrigin = CGPoint(x: contentX, y: y)
            y += footer.size.height
        }

        return PollSlot(
            rect: CGRect(
                x: origin.x, y: origin.y, width: cardWidth, height: y - origin.y + padding
            ),
            question: question,
            questionOrigin: questionOrigin,
            answers: answers,
            footer: footer,
            footerOrigin: footerOrigin,
            // A closed poll cannot be voted in, and a poll the reader has
            // already answered cannot be changed by this client — the route
            // replaces a ballot, and offering a second click that silently
            // rewrites the first is worse than not offering one.
            isVotable: !poll.isClosed && !poll.hasVoted
        )
    }

    /// `10 votes  83%`, joined so the pair reads as one figure.
    private static func tallyLabel(_ answer: Poll.Answer, in poll: Poll) -> String {
        let percent = Int((poll.share(of: answer) * 100).rounded())
        let votes = answer.count == 1 ? "1 vote" : "\(answer.count) votes"
        return "\(votes)   \(percent)%"
    }

    /// The line under the answers: the total, and what state the poll is in.
    private static func footerLabel(_ poll: Poll) -> String? {
        let total = poll.totalVotes
        let votes = total == 1 ? "1 vote" : "\(total) votes"
        if poll.isClosed { return "\(votes)  ·  Poll closed" }
        guard let expiresAt = poll.expiresAt else {
            return poll.showsResults ? votes : nil
        }
        let remaining = expiresAt.formatted(.relative(presentation: .named))
        // Before voting the total is deliberately absent: it is the one number
        // that hints at which way the room is leaning.
        return poll.showsResults ? "\(votes)  ·  Ends \(remaining)" : "Ends \(remaining)"
    }

    /// A plain styled run, laid out.
    ///
    /// The `style` is the message's own and is used for nothing but the
    /// inline-emoji box metrics `TimelineTextBlock` reads — which a run with no
    /// inline emoji never consults. Building a whole `MessageTextStyle` per
    /// label would be seven font lookups for three numbers nothing reads, and it
    /// cannot be built off the main actor anyway.
    private static func block(
        _ string: String,
        font: NSFont,
        color: NSColor,
        width: CGFloat,
        style: MessageTextStyle
    ) -> TimelineTextBlock {
        TimelineTextBlock(
            text: .plain(NSAttributedString(
                string: string,
                attributes: [.font: font, .foregroundColor: color]
            )),
            width: width,
            style: style
        )
    }
}
