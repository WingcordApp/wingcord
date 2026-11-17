import AppKit
import VisionKit

/// Live Text on a picture (decision 26): VisionKit's own overlay, so the text
/// in a screenshot can be selected and copied, and its links, dates and codes
/// act, as in Photos and Preview.
///
/// **Laid exactly over the picture**, following its zoom and pan, so the
/// overlay's own idea of where the image is never has to be translated.
@MainActor
final class ViewerLiveText {
    static var isSupported: Bool { ImageAnalyzer.isSupported }

    private let overlay = ImageAnalysisOverlayView()
    private let analyzer = ImageAnalyzer()
    private weak var host: NSView?
    private var analyzed: CGImage?
    private var task: Task<Void, Never>?

    init(host: NSView) {
        self.host = host
        overlay.preferredInteractionTypes = .automatic
    }

    /// Switches it on over `frame` for `image`, or off.
    func update(image: CGImage?, frame: CGRect, active: Bool) {
        guard Self.isSupported, let host else { return }
        guard active, let image else {
            task?.cancel()
            task = nil
            overlay.selectableItemsHighlighted = false
            overlay.removeFromSuperview()
            return
        }
        if overlay.superview == nil { host.addSubview(overlay) }
        if overlay.frame != frame { overlay.frame = frame }
        guard image !== analyzed else { return }
        analyzed = image
        overlay.analysis = nil
        task?.cancel()
        task = Task { [weak self, analyzer] in
            let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            guard let analysis = try? await analyzer.analyze(image, orientation: .up, configuration: configuration),
                  !Task.isCancelled, let self
            else { return }
            self.overlay.analysis = analysis
            // Photos' Live Text button: every piece of text lit at once.
            self.overlay.selectableItemsHighlighted = true
        }
    }

    func tearDown() {
        task?.cancel()
        overlay.removeFromSuperview()
    }
}
