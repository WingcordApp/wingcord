import Foundation

/// A file's size as Discord prints it everywhere it prints one — a file card,
/// an upload's card, a refusal's limit: humanize's `filesize` (`796873`).
///
/// **1,024s, two places, and "bytes" below a kilobyte**, with "," between
/// thousands and "." before the places whatever the language: "13.74 KB",
/// "10.00 MB", "1,023 bytes" — and "1,024.00 KB" one byte short of a
/// megabyte, because the unit is chosen before the rounding.
///
/// **Rounded as JavaScript's `toFixed` rounds**, a tie upward, which is not
/// what `%.2f` does: 1,152 bytes is "1.13 KB". A size over a power of 1,024
/// is a binary fraction, so the arithmetic here is whole numbers and exact.
public enum DiscordFileSize {
    private static let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]

    public static func text(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 bytes" }
        var unit = units.count - 1
        var divisor: Int64 = 1
        for index in units.indices {
            let next = divisor * 1024
            if Int64(bytes) < next || index == units.count - 1 {
                unit = index
                break
            }
            divisor = next
        }
        let value = Int64(bytes)
        guard unit > 0 else { return "\(grouped(value)) bytes" }
        // `toFixed(2)`, then `parseInt`: the whole part of the rounded value.
        let hundredths = roundedHalfUp(value * 100, over: divisor)
        let whole = hundredths / 100
        // The places are what is left over that whole part, rounded again —
        // humanize's own way, which is where "1,024.00" comes from.
        let remainder = abs(value - whole * divisor)
        let places = roundedHalfUp(remainder * 100, over: divisor) % 100
        return "\(grouped(whole)).\(places < 10 ? "0" : "")\(places) \(units[unit])"
    }

    /// `numerator / denominator`, a tie rounded up, for positive numbers.
    private static func roundedHalfUp(_ numerator: Int64, over denominator: Int64) -> Int64 {
        (numerator * 2 + denominator) / (denominator * 2)
    }

    private static func grouped(_ number: Int64) -> String {
        let digits = String(number)
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(digit)
        }
        return out
    }
}
