import Testing
@testable import WingcordCore

/// Discord's file sizes, against Discord's own formatter: every expected value
/// is what humanize's `filesize` (`796873`) returned in Node.
@Suite("Discord file size")
struct DiscordFileSizeTests {
    @Test("Sizes read as Discord prints them", arguments: [
        (-5, "0 bytes"),
        (0, "0 bytes"),
        (1, "1 bytes"),
        (512, "512 bytes"),
        (999, "999 bytes"),
        (1000, "1,000 bytes"),
        (1023, "1,023 bytes"),
        (1024, "1.00 KB"),
        (1025, "1.00 KB"),
        (1126, "1.10 KB"),
        (1152, "1.13 KB"),
        (1536, "1.50 KB"),
        (2560, "2.50 KB"),
        (10239, "10.00 KB"),
        (14072, "13.74 KB"),
        (1047552, "1,023.00 KB"),
        (1048064, "1,023.50 KB"),
        (1048575, "1,024.00 KB"),
        (1048576, "1.00 MB"),
        (1153434, "1.10 MB"),
        (10485760, "10.00 MB"),
        (10485761, "10.00 MB"),
        (26214400, "25.00 MB"),
        (52428800, "50.00 MB"),
        (104857600, "100.00 MB"),
        (123456789, "117.74 MB"),
        (524288000, "500.00 MB"),
        (1073741824, "1.00 GB"),
        (1610612736, "1.50 GB"),
        (5368709120, "5.00 GB"),
        (1099511627776, "1.00 TB"),
        (1125899906842624, "1.00 PB"),
    ])
    func size(bytes: Int, expected: String) {
        #expect(DiscordFileSize.text(bytes) == expected)
    }
}
