import Foundation
import WingcordCore

/// The gate a community server puts in front of somebody who has just arrived:
/// the questions that decide what they can see, and the rules they have to agree
/// to before they can speak.
///
/// **This is not Channels & Roles wearing a different hat**, and building it as
/// one gets both wrong. They share one route and disagree about everything else:
///
///   - Channels & Roles is **ongoing and optional**. It is opened when somebody
///     wants more of a server; every chip saves on the click; leaving it
///     half-answered is a normal thing to do.
///   - This is a **gate**. It arrives unasked, it is answered once, and until it
///     is the server is not usable — `pending` is what Discord enforces, and a
///     pending member may read what `@everyone` may read and may not post.
///
/// They also ask different questions, and the server says which is which.
/// **`in_onboarding` is the split**, and on the captured server it is five
/// prompts against one: `GET /guilds/428691939861463042/onboarding` answers six
/// prompts of which exactly one has `in_onboarding: true` — which is why the
/// capture's flow reads "Question 1 of 1" over a server with six questions in
/// its Channels & Roles page. A gate that showed all six would ask five things
/// the server deliberately does not ask on the way in.
struct ServerJoinGate: Hashable, Sendable {
    var guildID: GuildID
    /// The invite this was reached through, when it was.
    ///
    /// Carried for one reason: `GET .../member-verification` takes an
    /// `invite_code`, and the capture sends it. Nil for a gate raised by opening
    /// a server from the rail, which is every gate that is not a fresh join.
    var inviteCode: String?

    /// Where the flow is.
    ///
    /// **Not an index into one list** — the steps are of three kinds and only
    /// the middle one repeats, so an index would need a lookup at every use to
    /// say what it pointed at.
    ///
    /// **No welcome step** (docs/BETA3.md §1.6): Discord's onboarding opens on
    /// its first question, and the welcome screen built a promise from the
    /// question count — "0 questions about what you're here for" for a server
    /// whose gate was up before its questions had arrived, or had none.
    enum Step: Hashable, Sendable {
        case question(Int)
        case rules
    }

    var step: Step = .question(0)

    /// Chosen option ids, across every prompt.
    ///
    /// **Seeded from `onboarding.responses`, never from an empty set.** The save
    /// replaces the account's whole answer set rather than merging into it, so a
    /// gate that started empty and submitted what it collected would delete the
    /// answers to every prompt it never showed — including the five
    /// Channels-&-Roles-only ones it is not allowed to ask about. That costs
    /// somebody their roles, silently, and the same trap is recorded on
    /// `OnboardingResponsesBody`.
    var selection: Set<UInt64> = []
    /// Whether the seed above has happened. The questions arrive on their own
    /// route, so the gate can be on screen before there is anything to seed
    /// from — and a seed that ran on an empty table would latch an empty set.
    var isSeeded = false

    var isSubmitting = false
    /// Set when the submit failed. **The gate stays up**: one that dismissed on
    /// a failed write would drop somebody into a server they still cannot speak
    /// in, with nothing on screen saying why.
    var failure: String?
}

// MARK: - Presentation

/// What the gate's pane draws.
struct ServerJoinGatePresentation: Hashable, Sendable {
    var guildID: GuildID
    var serverName: String
    var iconURL: URL?
    var monogram: String
    /// The picture across the top. Nil for a server with neither banner nor
    /// splash, which draws the ground rather than a grey box.
    var coverURL: URL?

    /// Which step of how many, for the progress rail. Both are 1-based counts of
    /// **real** steps: a server with no rules has no rules step, and a server
    /// with three questions has three.
    var stepNumber: Int
    var stepCount: Int

    var body: Body
    var isSubmitting: Bool
    var failure: String?
    var canGoBack: Bool
    /// What the forward control says and whether it may be pressed.
    ///
    /// There is no `isLoading` beside it, deliberately: this whole value is nil
    /// until the questions have arrived, and `ServerJoinGateContainer` draws the
    /// wait for that. A second flag saying the same thing is a second thing to
    /// keep in step.
    var forward: Forward

    enum Body: Hashable, Sendable {
        case question(Question)
        case rules(Rules)
    }

    struct Question: Hashable, Sendable {
        var promptID: UInt64
        var title: String
        /// "Choose one." / "Choose all that apply."
        var guidance: String
        /// Whether an answer is demanded. Read by the bar: a required question
        /// with nothing chosen says so, because a Next that refuses without
        /// explaining is the failure `Forward.blocked` is trying to avoid.
        var isRequired: Bool
        var options: [Option]
        /// "You will receive the @Forza FR role." — the sentence that turns an
        /// opt-in from a title into a consequence. Nil when the current answers
        /// grant no named role.
        var grants: String?

        struct Option: Hashable, Sendable, Identifiable {
            var id: UInt64
            var title: String
            var detail: String?
            var glyph: SurfaceGlyph
            var isSelected: Bool
            /// How many people already hold what this grants. Nil when unknown,
            /// so the row stays silent rather than printing zero.
            var memberCount: Int?
        }
    }

    struct Rules: Hashable, Sendable {
        /// The server's own paragraph above the list.
        var detail: String?
        var rules: [String]
    }

    /// The forward control, which is three different buttons.
    ///
    /// `skip` rather than a disabled `next` is Discord's own distinction and it
    /// is the difference between a question and a demand: `required` is a field
    /// on the prompt, and an optional prompt's forward button says *Skip*.
    enum Forward: Hashable, Sendable {
        case next
        case skip
        case finish
        /// A required question with nothing chosen. The control is present and
        /// refuses, rather than absent — a button that vanishes when you have
        /// not done the thing gives no clue what the thing was.
        case blocked

        var title: String {
            switch self {
            case .next, .blocked: "Next"
            case .skip: "Skip"
            case .finish: "Finish"
            }
        }

        var symbolName: String? {
            switch self {
            case .next, .skip, .blocked: "arrow.right"
            case .finish: nil
            }
        }

        var isEnabled: Bool { self != .blocked }
    }
}
