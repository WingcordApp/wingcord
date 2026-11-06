import SwiftUI

/// Wingcord's wings: the three feathers on the app icon, as a shape.
///
/// **Read from the icon's own artwork** (`Packaging/AppIcon.icon/Assets/
/// Untitled.svg`, a 1024 box), so the QR code's middle and the welcome's
/// particles are the icon's mark and not a drawing of it. The paths are
/// absolute moves and cubic curves only, which is all `SVGPath` reads.
nonisolated struct WingsShape: Shape {
    /// The three feathers' bounds in the icon's 1024 box.
    static let artBounds = CGRect(x: 247.279, y: 246.29, width: 779.375 - 247.279, height: 771.062 - 246.29)

    static let feathers: [String] = [
        "M247.279 384.114C259.284 395.113 272.193 405.083 285.87 413.917C293.043 419.267 303.918 425.377 311.743 429.898C364.573 460.655 423.739 473.678 484.324 477.387C566.734 482.431 657.927 462.087 732.498 507.161C755.042 520.787 767.012 534.43 779.375 557.172C696.609 514.787 610.71 564.868 527.602 576.252C505.312 579.305 480.769 576.122 458.808 572.038C375.895 555.308 325.641 513.275 279.396 444.763C276.504 439.571 272.407 433.542 269.248 428.135C260.826 414.036 253.482 399.321 247.279 384.114Z",
        "M327.586 246.29C348.816 269.697 390.409 299.205 418.533 313.353C428.496 319.359 443.594 325.808 454.324 330.29C486.561 343.755 521.038 352.974 554.906 361.39C611.545 375.465 670.976 386.538 716.769 425.545C735.488 441.49 745.714 453.784 756.908 475.943C722.023 456.747 678.904 447.421 639.518 447.996C576.1 448.923 510.87 446.556 452.75 417.961C424.5 404.062 395.759 376.675 377.031 351.215C353.299 319.959 338.853 283.542 327.586 246.29Z",
        "M683.789 573.222C687.546 573.056 691.753 573.147 695.565 573.349C714.725 574.365 740.486 579.599 753.983 594.398C761.295 602.416 764.278 613.33 763.523 624.076C761.929 646.76 748.156 670.391 733.456 687.243C728.48 692.946 722.363 698.268 716.757 703.262C720.509 689.851 723.825 677.26 721.096 663.147C716.872 641.47 693.232 638.723 675.756 644.762C668.664 647.145 661.881 650.558 655.314 654.126C614.022 676.563 574.306 701.71 531.481 721.293C497.621 736.777 462.569 750.348 426.163 758.569C378.501 770.215 338.824 771.062 290.525 766.273C294.725 764.307 301.757 762.166 306.323 760.514C315.179 757.292 323.973 753.9 332.7 750.342C358.738 739.68 383.973 727.154 408.208 712.86C429.175 700.562 449.642 687.431 469.561 673.5C492.107 657.648 513.235 640.216 536.807 625.792C581.405 598.501 630.805 575.249 683.789 573.222Z",
    ]

    /// All three, in the icon's own coordinates. Parsed once.
    static let artPath: Path = feathers.reduce(into: Path()) { path, data in
        path.addPath(SVGPath.parse(data))
    }

    func path(in rect: CGRect) -> Path {
        let bounds = Self.artBounds
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let x = rect.midX - bounds.width * scale / 2
        let y = rect.midY - bounds.height * scale / 2
        let transform = CGAffineTransform(translationX: x, y: y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.minX, y: -bounds.minY)
        return Self.artPath.applying(transform)
    }
}

/// The smallest SVG path reader that reads the icon: absolute `M`, `L`, `C` and
/// `Z`, with a command's numbers repeating for as long as they keep coming.
nonisolated enum SVGPath {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character?

        func flush() {
            guard let command else { return }
            switch command {
            case "M":
                var index = 0
                while index + 1 < numbers.count {
                    let point = CGPoint(x: numbers[index], y: numbers[index + 1])
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    index += 2
                }
            case "L":
                var index = 0
                while index + 1 < numbers.count {
                    path.addLine(to: CGPoint(x: numbers[index], y: numbers[index + 1]))
                    index += 2
                }
            case "C":
                var index = 0
                while index + 5 < numbers.count {
                    path.addCurve(
                        to: CGPoint(x: numbers[index + 4], y: numbers[index + 5]),
                        control1: CGPoint(x: numbers[index], y: numbers[index + 1]),
                        control2: CGPoint(x: numbers[index + 2], y: numbers[index + 3])
                    )
                    index += 6
                }
            case "Z", "z":
                path.closeSubpath()
            default:
                break
            }
            numbers.removeAll(keepingCapacity: true)
        }

        var token = ""
        func endNumber() {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }
        for character in data {
            if character.isLetter && character != "e" && character != "E" {
                endNumber()
                flush()
                command = character
            } else if character == " " || character == "," {
                endNumber()
            } else if character == "-", !token.isEmpty, token.last != "e", token.last != "E" {
                endNumber()
                token.append(character)
            } else {
                token.append(character)
            }
        }
        endNumber()
        flush()
        return path
    }
}
