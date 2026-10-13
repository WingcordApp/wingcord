import Testing
@testable import WingcordCore

/// Discord's desktop conversion of a HEIC or JXR picture to a JPEG, and the
/// words it refuses an upload in: the matches and names below are what
/// `452661`'s own functions gave in Node.
@Suite("Upload conversion")
struct UploadConversionTests {
    @Test("Which pictures are converted, and what they are called after", arguments: [
        ("IMG_1.HEIC", nil, .heic, "IMG_1.jpg"),
        ("photo.heif", "image/heif", .heic, "photo.jpg"),
        ("x.hif", nil, .heic, "x.jpg"),
        ("shot.png", "image/heic", .heic, "shot.png.jpg"),
        ("seq.heics", "image/heic-sequence", .heic, "seq.heics.jpg"),
        ("scan.JXR", nil, .jxr, "scan.jpg"),
        ("a.wdp", "image/vnd.ms-photo", .jxr, "a.jpg"),
        ("b.hdp", nil, .jxr, "b.jpg"),
        ("c.jpg", "image/jpeg", nil, "c.jpg.jpg"),
        ("noext", nil, nil, "noext.jpg"),
        ("noext", "image/heif-sequence", .heic, "noext.jpg"),
        ("weird.heic.png", nil, nil, "weird.heic.png.jpg"),
        ("UPPER.HeIf", "image/HEIF", .heic, "UPPER.jpg"),
    ] as [(String, String?, UploadConversion?, String)])
    func conversion(name: String, type: String?, expected: UploadConversion?, jpeg: String) {
        #expect(UploadConversion(filename: name, contentType: type) == expected)
        #expect(UploadConversion.jpegName(for: name) == jpeg)
    }

    @Test("A type is matched as written, as Discord's set matches it")
    func caseSensitiveType() {
        #expect(UploadConversion(filename: "x.png", contentType: "image/HEIC") == nil)
    }

    @Test("Discord's quality and ceiling for each")
    func parameters() {
        #expect(UploadConversion.heic.quality == 0.80)
        #expect(UploadConversion.heic.maximumBytes == 20_971_520)
        #expect(UploadConversion.jxr.quality == 0.85)
        #expect(UploadConversion.jxr.maximumBytes == 52_428_800)
    }

    @Test("A refusal says the limit Discord's way, and Classic in its own words")
    func refusalWords() {
        let ten = AttachmentLimits.bytes(forPremium: .none)
        #expect(AttachmentLimits.tooLargeHelp(limit: ten, premium: .none) == "Max file size is 10.00 MB please.")
        #expect(AttachmentLimits.tooLargeHelp(limit: 50 * 1_048_576, premium: .classic) == "Max file size for Nitro Classic is 50.00 MB please.")
        #expect(AttachmentLimits.tooLargeHelp(limit: 50 * 1_048_576, premium: .basic) == "Max file size is 50.00 MB please.")
        #expect(AttachmentLimits.totalTooLargeHelp == "Total message size must be less than 500.00 MB")
        #expect(AttachmentLimits.tooManyHelp(limit: 10) == "You can only upload 10 files at a time!")
    }
}
