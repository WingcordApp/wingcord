import Foundation

/// Discord's volume slider, which is not linear (its module 792251).
///
/// **A slider position is not a gain.** Below 100% the gain is the position
/// raised to the power 2.8, so the first half of the slider holds the quiet
/// end where an ear tells levels apart; above it, every further 100% is
/// another six decibels. Discord stores and syncs the **gain** (×100) and draws
/// the **position**, for the microphone, the speakers, each person and each
/// stream alike — so a value read from its settings has to go through this
/// before a slider shows it, or a person Discord set to half is drawn at 14%.
public enum VolumeCurve {
    /// The gain a slider position gives, both as fractions: 1 is 100%.
    public static func gain(atPosition position: Double) -> Double {
        guard position > 0 else { return 0 }
        return position < 1 ? pow(position, 2.8) : pow(10, (position - 1) * 6 / 20)
    }

    /// Where a gain sits on the slider.
    public static func position(ofGain gain: Double) -> Double {
        guard gain > 0 else { return 0 }
        return gain < 1 ? pow(gain, 1 / 2.8) : 20 * log10(gain) / 6 + 1
    }
}
