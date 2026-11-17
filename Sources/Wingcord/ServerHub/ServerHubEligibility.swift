/// Where a server stands with Discord's `2026-09-guild-spaces` experiment, the
/// first half of Discord's rule for showing its hub (`AppModel.offersServerHub`).
enum ServerHubEligibility: Sendable {
    case inExperiment
    case notInExperiment
    /// READY sent no assignments to evaluate.
    case unknown
}
