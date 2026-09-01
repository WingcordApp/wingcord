import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import WingcordCore

// MARK: - Somebody else's picture
//
// `AVSampleBufferDisplayLayer`, fed the H.264 the engine reassembled. There is
// no decoder in this app: the layer decodes on the same hardware a
// `VTDecompressionSession` would use and puts the result on its own surface, so
// the path from the network to the screen is one hand-off with no pixel buffer,
// no texture upload and no draw of ours in the middle.
//
// **Frames are enqueued on the network's queue, and that is allowed here and
// nowhere else in AVFoundation.** `sampleBufferRenderer` exists precisely to be
// safe off the main thread; the layer's own deprecated `enqueue` is not. A
// client that hops to the main actor per frame adds a scheduling delay to
// thirty frames a second on the one path that can least afford it.
/// One frame on its way from the network's queue to the renderer.
///
/// `CMSampleBuffer` is a CoreMedia object and thread-safe by construction; what
/// it is not is `Sendable`, and a stream between two isolation domains needs it
/// to be. At file scope rather than nested, because a type nested inside a
/// `@MainActor` class inherits that isolation and its initialiser could then not
/// be called from the network's queue at all. `nonisolated` for the same reason
/// one step out: the app target's default isolation is the main actor, so a
/// bare struct here would be built on it too.
private nonisolated struct SampleBox: @unchecked Sendable {
    let sample: CMSampleBuffer
}

struct VoiceVideoView: NSViewRepresentable {
    var userID: UserID
    /// Installs and removes the sink. A closure rather than a controller
    /// reference, so this view holds nothing that outlives it.
    var attach: (UserID, (@Sendable (CMSampleBuffer) -> Void)?) -> Void

    func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        attach(userID, view.sink)
        return view
    }

    func updateNSView(_ view: VideoHostView, context: Context) {
        guard context.coordinator.userID != userID else { return }
        attach(context.coordinator.userID, nil)
        context.coordinator.userID = userID
        view.reset()
        attach(userID, view.sink)
    }

    static func dismantleNSView(_ view: VideoHostView, coordinator: Coordinator) {
        // **Cleared, not merely released.** A sink left installed is a display
        // layer being fed after its window has gone, which keeps the whole
        // decode path alive for a tile nobody can see.
        coordinator.detach?(coordinator.userID, nil)
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.userID = userID
        coordinator.detach = attach
        return coordinator
    }

    @MainActor
    final class Coordinator {
        var userID = UserID(rawValue: 0)
        var detach: ((UserID, (@Sendable (CMSampleBuffer) -> Void)?) -> Void)?
    }

    /// The layer-backed host.
    ///
    /// Layer-backed with `wantsLayer` set in `init`, because a display layer
    /// added to a view that is not layer-backed has no compositor behind it —
    /// it renders nothing and reports no error.
    @MainActor
    final class VideoHostView: NSView {
        private let display = AVSampleBufferDisplayLayer()
        /// SDK 27 moved enqueueing behind a `Receiver` obtained from a render
        /// synchroniser, and the whole of that API is main-actor bound —
        /// `AVSampleBufferDisplayLayer` is `NS_SWIFT_UI_ACTOR` now. The
        /// renderer's own thread-safe `enqueue` is deprecated with it.
        private let synchronizer = AVSampleBufferRenderSynchronizer()
        private var receiver: AVSampleBufferVideoRenderer.Receiver?
        private var pump: Task<Void, Never>?
        private var inbox: AsyncStream<SampleBox>.Continuation?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            // The picture keeps its aspect and is fitted, never filled: a
            // camera cropped to a tile's shape cuts somebody's head off, and a
            // shared screen cropped to it hides the half being pointed at.
            display.videoGravity = .resizeAspect
            // No implicit animation on the layer's geometry. Core Animation
            // would otherwise cross-fade every resize of a live video surface,
            // which reads as the picture smearing whenever the grid reflows.
            display.actions = ["bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(display)

            receiver = synchronizer.sampleBufferReceiver(adding: display.sampleBufferRenderer)
            synchronizer.setRate(1, time: .zero)
            startPump()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        deinit {
            pump?.cancel()
            inbox?.finish()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            display.frame = bounds
            CATransaction.commit()
        }

        /// **Ordered, and bounded.** An `AsyncStream` preserves the order it was
        /// written in, which a `Task` per frame does not — and out-of-order
        /// H.264 is not a glitch, it is a decoder that stops until the next
        /// keyframe. The buffer is small on purpose: if the main actor is
        /// stalled deeply enough to fall eight frames behind, the right answer
        /// for live video is to drop what is stale rather than to play a queue
        /// of it late.
        private func startPump() {
            let (stream, continuation) = AsyncStream<SampleBox>.makeStream(
                bufferingPolicy: .bufferingNewest(8)
            )
            inbox = continuation
            pump = Task { @MainActor [weak self] in
                for await box in stream {
                    guard let self, let receiver else { return }
                    let ready = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(
                        unsafeBuffer: box.sample
                    )
                    // **A refused frame leaves the renderer needing a flush
                    // before it will take anything again.** Without it the tile
                    // freezes on its last picture for the rest of the call, and
                    // nothing anywhere reports an error.
                    switch receiver.enqueueImmediately(ready) {
                    case .enqueued, .enqueuedWithDecodeFailures, .cancelledDueToFlush:
                        break
                    case .cancelledDueToFlushRequiredToResume, .cancelledDueToError:
                        receiver.flush()
                    @unknown default:
                        break
                    }
                }
            }
        }

        /// Handed to the engine, and called on the network's queue.
        var sink: @Sendable (CMSampleBuffer) -> Void {
            let inbox = self.inbox
            return { sample in inbox?.yield(SampleBox(sample: sample)) }
        }

        func reset() {
            receiver?.flush()
        }
    }
}

// MARK: - Your own picture

/// The self-view.
///
/// **The capture session's own preview layer, never the encoded frames.** A
/// preview is a separate hardware path straight from the sensor with no round
/// trip through an encoder, a network or a decoder — which is why every
/// reference client's self-view has no latency and every hand-rolled one has
/// about two hundred milliseconds of it.
struct CameraPreviewView: NSViewRepresentable {
    var session: AVCaptureSession?
    /// Mirrored, because a self-view that is not is a self-view people cannot
    /// use to aim. Nobody else sees the mirroring.
    var isMirrored = true

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.attach(session, mirrored: isMirrored)
        return view
    }

    func updateNSView(_ view: PreviewHostView, context: Context) {
        view.attach(session, mirrored: isMirrored)
    }

    final class PreviewHostView: NSView {
        private var preview: AVCaptureVideoPreviewLayer?
        private var attached: AVCaptureSession?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        func attach(_ session: AVCaptureSession?, mirrored: Bool) {
            guard session !== attached else {
                preview?.connection?.isVideoMirrored = mirrored
                return
            }
            preview?.removeFromSuperlayer()
            attached = session
            guard let session else {
                preview = nil
                return
            }
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            if let connection = layer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
            self.layer?.addSublayer(layer)
            preview = layer
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview?.frame = bounds
            CATransaction.commit()
        }
    }
}
