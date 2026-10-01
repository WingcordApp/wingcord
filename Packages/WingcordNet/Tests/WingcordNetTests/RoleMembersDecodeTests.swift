import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The ids behind a role mention's flyout, from `member ids and counts.har`,
/// trimmed to a few.
struct RoleMembersDecodeTests {

    @Test("A role's member ids arrive as strings and decode as ids")
    func memberIDs() throws {
        let captured = #"["207799578524250355", "213925156686341573", "224488443479064576"]"#
        let ids = try JSONDecoder().decode([UserID].self, from: Data(captured.utf8))
        #expect(ids == [
            UserID(rawValue: 207_799_578_524_250_355),
            UserID(rawValue: 213_925_156_686_341_573),
            UserID(rawValue: 224_488_443_479_064_576),
        ])
    }
}
