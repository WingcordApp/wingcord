import Foundation

// MARK: - Applying to join
//
// Discord's member verification modal (`823591`): a server's rules to agree to
// and, where it reviews applications, its questions. One route answers both
// (`GET /guilds/{id}/member-verification`) and one route takes the answers
// (`PUT /guilds/{id}/requests/@me`).

/// One answer, in the shape Discord sends it.
public enum JoinApplicationAnswer: Hashable, Sendable {
    /// The rules checkbox — `true` or `false` on the wire.
    case agreed(Bool)
    /// A short answer or a paragraph.
    case text(String)
    /// A multiple-choice answer: **the choice's index**, a number on the wire
    /// (`{name: choice, value: index}` in `414626`), never its words.
    case choice(Int)
}

/// Somebody filling in a server's form.
public struct JoinApplication: Hashable, Sendable {
    public var form: MemberVerification
    public var answers: [UUID: JoinApplicationAnswer]

    /// A short answer's limit — `cs` in `260197`.
    public static let textLimit = 150
    /// A paragraph's limit — `nQ`; Discord shows the characters left.
    public static let paragraphLimit = 1000

    public init(form: MemberVerification, answers: [UUID: JoinApplicationAnswer] = [:]) {
        self.form = form
        self.answers = answers
    }

    /// The rules agreed to and nothing else — the rules gate's whole answer.
    public static func agreeing(to form: MemberVerification) -> JoinApplication {
        var application = JoinApplication(form: form)
        if let terms = form.termsField { application.answers[terms.id] = .agreed(true) }
        return application
    }

    /// Discord's `Ge` (`709977`), a field at a time.
    ///
    /// A field that is not required always passes. A required one passes when
    /// the rules are ticked, the text has something besides spaces in it, or a
    /// choice is made. A kind this client has never seen cannot be answered
    /// here, so it never passes — the server would refuse the form anyway.
    public func isAnswered(_ field: JoinApplicationForm.Field) -> Bool {
        guard field.isRequired else { return true }
        switch (field.kind, answers[field.id]) {
        case (.terms, .agreed(let agreed)?):
            return agreed
        case (.textInput, .text(let text)?), (.paragraph, .text(let text)?):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case (.multipleChoice, .choice?):
            return true
        default:
            return false
        }
    }

    /// Every field passes — what enables Submit.
    public var isComplete: Bool { form.fields.allSatisfy(isAnswered) }

    /// Whether what is missing includes the rules, which picks the sentence
    /// Discord shows over a disabled Submit.
    public var isMissingAgreement: Bool {
        form.fields.contains { $0.kind.isTerms && !isAnswered($0) }
    }

    /// The sentence over a disabled Submit — `PLNbh3` / `brWmV2`.
    public var incompleteMessage: String {
        isMissingAgreement
            ? "All required fields must be filled, including agreeing to the rules."
            : "All required fields must be filled."
    }

    /// Whether closing would throw anything away.
    ///
    /// **Something typed or chosen in a question**, which is when Discord asks
    /// "Are you sure? Your progress will be lost." Its own test runs `Ge`,
    /// which passes every optional question untouched — so a form with one
    /// asks before closing even when nothing was written. This asks only when
    /// something was.
    public var hasProgress: Bool {
        answers.contains { id, answer in
            guard form.fields.contains(where: { $0.id == id && !$0.kind.isTerms }) else { return false }
            switch answer {
            case .agreed: return false
            case .text(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .choice: return true
            }
        }
    }

    /// A text answer, cut to its field's limit.
    public static func clamped(_ text: String, for kind: JoinApplicationForm.Field.Kind) -> String {
        let limit = switch kind {
        case .paragraph: paragraphLimit
        default: textLimit
        }
        return text.count > limit ? String(text.prefix(limit)) : text
    }
}
