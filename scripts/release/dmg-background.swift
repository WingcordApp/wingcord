// The disk image's background (docs/UPDATES.md D9): Packaging/DMG/WingcordBackground.png,
// moved sideways so its arrow sits mid-window, at the window's size and twice it, in the
// one TIFF Finder takes for both — WingcordBackground.tiff, which release.sh puts in the
// image's hidden .background folder.
//
//   swift scripts/release/dmg-background.swift <source.png> <out.tiff> [shift in source pixels]
//
// The window is 660 × 440 points (3:2, the source's shape). The shift repeats the source's
// edge into the gap it opens, so it suits a plain edge like this one's.
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let window = CGSize(width: 660, height: 440)
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: dmg-background.swift <source.png> <out.tiff> [shift]\n".utf8))
    exit(2)
}
let shift = arguments.count > 3 ? Double(arguments[3]) ?? 0 : 0
guard let source = CIImage(contentsOf: URL(fileURLWithPath: arguments[1])) else { fatalError("can't read \(arguments[1])") }
let extent = source.extent
let moved = source.clampedToExtent()
    .transformed(by: CGAffineTransform(translationX: shift, y: 0))
    .cropped(to: extent)
let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func render(scale: CGFloat, to url: URL) throws {
    let size = CGSize(width: window.width * scale, height: window.height * scale)
    let filter = CIFilter(name: "CILanczosScaleTransform")!
    filter.setValue(moved, forKey: kCIInputImageKey)
    filter.setValue(size.height / extent.height, forKey: kCIInputScaleKey)
    filter.setValue(size.width / extent.width / (size.height / extent.height), forKey: kCIInputAspectRatioKey)
    let scaled = filter.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    let image = context.createCGImage(scaled, from: CGRect(origin: .zero, size: size))!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    // 72 and 144 dots per inch: what tells Finder which is the Retina one.
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { fatalError("can't write \(url.path)") }
}

let single = folder.appending(path: "background.png")
let double = folder.appending(path: "background@2x.png")
try render(scale: 1, to: single)
try render(scale: 2, to: double)
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", single.path, double.path, "-out", arguments[2]]
try tiffutil.run()
tiffutil.waitUntilExit()
try? FileManager.default.removeItem(at: folder)
exit(tiffutil.terminationStatus)
