import AVFoundation
import QuartzCore

/// A camera's capture session, safe to hand across an isolation boundary, and
/// the only way a preview layer joins it or leaves it.
///
/// **Everything that changes a session happens on the queue that owns it**,
/// previews included. Binding a preview layer reconfigures the session, and
/// AVFoundation throws when `startRunning` or `stopRunning` meets a
/// configuration still open on another thread: "startRunning may not be called
/// between calls to beginConfiguration and commitConfiguration". That was the
/// capture bar's crash (issue #22, report WC-VJEX): its bubble bound a preview
/// on the main thread while the camera's queue was starting the camera. A probe
/// of 400 starts and stops against main-thread binds threw twice; the same work
/// on one queue never did. So the session itself is not handed out: a view
/// gets this, and its preview joins and leaves through it.
public struct CaptureSessionHandle: @unchecked Sendable, Equatable {
    /// Only for this package: anything else that bound a layer to it directly
    /// would be back on the wrong thread.
    let session: AVCaptureSession
    /// The queue every change to `session` is made on: its configuration, its
    /// start and stop, and its previews.
    let queue: DispatchQueue

    init(session: AVCaptureSession, queue: DispatchQueue) {
        self.session = session
        self.queue = queue
    }

    /// The same camera, whichever value carries it.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session === rhs.session
    }

    /// Shows the camera in `layer`, after whatever the camera's queue is doing
    /// (a start, a stop). Hand it a layer made without a session.
    public func attach(_ layer: AVCaptureVideoPreviewLayer, mirrored: Bool) {
        let preview = Preview(layer: layer)
        queue.async { [self] in
            Self.change {
                preview.layer.session = session
                Self.mirror(preview.layer, mirrored)
            }
        }
    }

    /// Mirrors the picture in `layer`, or stops mirroring it.
    public func setMirrored(_ mirrored: Bool, on layer: AVCaptureVideoPreviewLayer) {
        let preview = Preview(layer: layer)
        queue.async {
            Self.change { Self.mirror(preview.layer, mirrored) }
        }
    }

    /// Takes `layer` off the camera, on the camera's queue. The layer is held
    /// until then, so it can't be freed (which also takes it off) on another
    /// thread first.
    public func detach(_ layer: AVCaptureVideoPreviewLayer) {
        let preview = Preview(layer: layer)
        queue.async {
            Self.change { preview.layer.session = nil }
        }
    }

    private static func mirror(_ layer: AVCaptureVideoPreviewLayer, _ mirrored: Bool) {
        guard let connection = layer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    /// A layer change off the main thread: in a transaction of its own, so it
    /// lands at once, and with nothing animated.
    private static func change(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// A preview layer on its way to the camera's queue. Core Animation lets
    /// a layer be changed from any thread inside a transaction; the type only
    /// says so.
    private struct Preview: @unchecked Sendable {
        let layer: AVCaptureVideoPreviewLayer
    }
}
