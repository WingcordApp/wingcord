import AppKit
import AVFoundation
import WingcordVoice

/// The camera's bubble while the capture bar is up or recording — the
/// session's own preview layer in a round floating window the reader can drag
/// anywhere. The camera is recorded to a file of its own; this window is left
/// out of the screen's picture.
final class CameraBubblePanel: NSPanel {
    static let side: CGFloat = 196

    init(session: CaptureSessionHandle) {
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
        let preview = AVCaptureVideoPreviewLayer(session: session.session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.cornerRadius = Self.side / 2
        preview.masksToBounds = true
        // A mirror, as every self-view is: moving left moves left.
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        let rim = CALayer()
        rim.frame = view.bounds
        rim.cornerRadius = Self.side / 2
        rim.borderWidth = 2
        rim.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        view.layer?.addSublayer(preview)
        view.layer?.addSublayer(rim)
        contentView = view
    }

    /// The bottom-right corner of `screen`, clear of the Dock.
    func placeInCorner(of screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        setFrameOrigin(CGPoint(x: visible.maxX - Self.side - 32, y: visible.minY + 32))
    }
}
