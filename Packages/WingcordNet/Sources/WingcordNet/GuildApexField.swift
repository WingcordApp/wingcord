import Foundation
import WingcordCore

/// A guild object's `experiments` as it can arrive: its apex assignments, a
/// null, or a shape this client can't read (the last two both mean none).
/// Never throws: it rides every READY.
struct GuildApexField: Decodable, Sendable {
    var assignments: [UInt32: ApexAssignment]?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard !container.decodeNil(), let tree = try? container.decode(JSONTree.self), tree.object != nil else {
            assignments = nil
            return
        }
        assignments = Dictionary(
            ExperimentWire.assignments(tree).map { ($0.hash, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
