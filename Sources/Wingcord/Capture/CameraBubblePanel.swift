import AppKit
import AVFoundation
import WingcordVoice

/// The camera's bubble while the capture bar is up or recording — the
/// session's own preview layer in a round floating window the reader can drag
/// anywhere. The camera is recorded to a file of its own; this window is left
/// out of the screen's picture.
///
/// **Its preview joins and leaves the camera on the camera's queue**
/// (`CaptureSessionHandle`), never here: binding it on the main thread while
/// the camera started is what crashed the capture bar (issue #22).
final class CameraBubblePanel: NSPanel {
    static let side: CGFloat = 196

    private let camera: CaptureSessionHandle
    private let preview = AVCaptureVideoPreviewLayer()

    init(camera: CaptureSessionHandle) {
        self.camera = camera
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: Self.side, height: Self.side),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false

        let view = NSView(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        view.wantsLayer = true
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.cornerRadius = Self.side / 2
        preview.masksToBounds = true
        let rim = CALayer()
        rim.frame = view.bounds
        rim.cornerRadius = Self.side / 2
        rim.borderWidth = 2
        rim.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        view.layer?.addSublayer(preview)
        view.layer?.addSublayer(rim)
        contentView = view
        // A mirror, as every self-view is: moving left moves left.
        camera.attach(preview, mirrored: true)
    }

    /// The bottom-right corner of `screen`, clear of the Dock.
    func placeInCorner(of screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        setFrameOrigin(CGPoint(x: visible.maxX - Self.side - 32, y: visible.minY + 32))
    }

    /// Comes in with the camera's picture already in it, so the bubble never
    /// shows an empty ring first.
    func fadeIn() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Takes the preview off the camera, on the camera's queue: before the
    /// camera stops, and before this window is let go (freeing a bound layer
    /// takes it off the session too, on whatever thread frees it).
    func detachCamera() {
        preview.removeFromSuperlayer()
        camera.detach(preview)
    }
}
