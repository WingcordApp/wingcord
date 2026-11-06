import CoreGraphics
import Foundation
import SwiftUI
import Testing
import Vision
@testable import Wingcord

/// The login code, drawn as Wingcord's, still has to be a QR code: every drawing
/// here is decoded with Vision, which is what a phone's camera runs, and has to
/// come back as exactly the link it was made from (docs/LOGIN-ONBOARDING.md D7).
@MainActor
@Suite("QR code login, as drawn")
struct QRCodeScanTests {

    /// A link shaped like the gateway's: 43 characters of base64url fingerprint.
    private func link(_ seed: Int) -> URL {
        var generator = SeededGenerator(seed: UInt64(seed))
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let fingerprint = String((0..<43).map { _ in alphabet.randomElement(using: &generator)! })
        return URL(string: "https://discord.com/ra/\(fingerprint)")!
    }

    private func render(_ matrix: QRMatrix, side: CGFloat = 200, scale: CGFloat = 2) -> CGImage? {
        let view = ZStack {
            Color.white
            QRModules(matrix: matrix, reveal: 1, isPlaceholder: false, inkOpacity: 1)
        }
        .frame(width: side, height: side)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage
    }

    private func decode(_ image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    @Test("The link is a 41-module code at quartile correction: no alignment pattern under the wings")
    func version() throws {
        let matrix = try #require(QRMatrix.make(link(1).absoluteString))
        #expect(matrix.size == 41)
    }

    @Test("Read the right way up: eyes top left, top right and bottom left, never bottom right")
    func orientation() throws {
        let matrix = try #require(QRMatrix.make(link(2).absoluteString))
        let last = matrix.size - 1
        // A finder, exactly: a dark ring, a light ring, a dark 3×3 heart. A loose
        // test passes on the bottom-right alignment pattern by chance.
        func isEye(atColumn x: Int, row y: Int) -> Bool {
            for dy in 0..<7 {
                for dx in 0..<7 {
                    let ring = max(abs(dx - 3), abs(dy - 3))
                    let dark = ring == 3 || ring <= 1
                    if matrix[x + dx, y + dy] != dark { return false }
                }
            }
            return true
        }
        #expect(isEye(atColumn: 0, row: 0))
        #expect(isEye(atColumn: last - 6, row: 0))
        #expect(isEye(atColumn: 0, row: last - 6))
        #expect(!isEye(atColumn: last - 6, row: last - 6))
    }

    @Test("Every drawing decodes to its own link", arguments: [3, 4, 5, 6, 7, 8])
    func scans(seed: Int) throws {
        let url = link(seed)
        let matrix = try #require(QRMatrix.make(url.absoluteString))
        let image = try #require(render(matrix))
        #expect(try decode(image) == [url.absoluteString])
    }

    @Test("Small, at one pixel a point, it still decodes")
    func scansSmall() throws {
        let url = link(9)
        let matrix = try #require(QRMatrix.make(url.absoluteString))
        let image = try #require(render(matrix, side: 160, scale: 1))
        #expect(try decode(image) == [url.absoluteString])
    }

    @Test("The placeholder is not a code: nothing decodes")
    func placeholder() throws {
        let image = try #require(render(QRMatrix.placeholder()))
        #expect(try decode(image).isEmpty)
    }

    @Test("The wings sit in a cleared square of odd side, a quarter of the code")
    func logoArea() throws {
        let matrix = try #require(QRMatrix.make(link(10).absoluteString))
        let side = matrix.logoSide()
        #expect(side % 2 == 1)
        #expect(side == 11)
        #expect(matrix.isUnderLogo(x: 20, y: 20, side: side))
        #expect(!matrix.isUnderLogo(x: 14, y: 20, side: side))
    }

    @Test("The wings parse into three closed feathers inside the icon's box")
    func wings() {
        // The box is the paths' numbers, control points included, so the curves
        // sit inside it and touch it where a feather's tip is an end point.
        let bounds = WingsShape.artPath.boundingRect
        #expect(WingsShape.artBounds.insetBy(dx: -1, dy: -1).contains(bounds))
        #expect(abs(bounds.minX - WingsShape.artBounds.minX) < 1)
        #expect(abs(bounds.minY - WingsShape.artBounds.minY) < 1)
        let fitted = WingsShape().path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).boundingRect
        #expect(fitted.width <= 100.5 && fitted.height <= 100.5)
        #expect(fitted.width > 95 || fitted.height > 95)
    }
}

/// SplitMix64, so a test's made-up fingerprints are the same every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
