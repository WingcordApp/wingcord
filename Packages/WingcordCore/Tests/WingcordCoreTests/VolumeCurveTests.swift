import Foundation
import Testing
@testable import WingcordCore

/// Discord's slider curve, held to values computed by running its module
/// 792251 (`w` and `M`, with their default scale of 100) in node — not
/// derived from this port.
@Suite("Volume curve")
struct VolumeCurveTests {

    @Test("Discord's positions give Discord's gains")
    func gains() {
        // w(50) = 14.358729…, w(100) = 100, w(200) = 199.526231…, w(0) = 0
        #expect(abs(VolumeCurve.gain(atPosition: 0.5) - 0.143_587_29) < 0.000_001)
        #expect(VolumeCurve.gain(atPosition: 1) == 1)
        #expect(abs(VolumeCurve.gain(atPosition: 2) - 1.995_262_31) < 0.000_001)
        #expect(VolumeCurve.gain(atPosition: 0) == 0)
    }

    /// A stream's default of 18 sits a little past half — where Discord's
    /// Stream Volume starts.
    @Test("Gains go back to their positions, and a stream's 18 sits at 54%")
    func positions() {
        for position in stride(from: 0.05, through: 2, by: 0.05) {
            let back = VolumeCurve.position(ofGain: VolumeCurve.gain(atPosition: position))
            #expect(abs(back - position) < 0.000_001)
        }
        // M(18) = 54.2033208…
        #expect(abs(VolumeCurve.position(ofGain: 0.18) - 0.542_033_2) < 0.000_001)
    }
}
