import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import WingcordCore
import WingcordVoice

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
    /// Told how many pixels the picture is drawn at, and zero when it goes —
    /// Discord's `VIDEO_SIZE_UPDATE`, which sizes a one-to-one call's want.
    var reportPixels: ((UserID, Int) -> Void)?

    func makeNSView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        attach(userID, view.sink)
        view.startOver = { [weak view, coordinator = context.coordinator] in
            guard let view else { return }
            coordinator.attach?(coordinator.userID, view.sink)
        }
        view.onPixels = { [coordinator = context.coordinator] pixels in
            coordinator.reportPixels?(coordinator.userID, pixels)
        }
        return view
    }

    func updateNSView(_ view: VideoHostView, context: Context) {
        guard context.coordinator.userID != userID else { return }
        attach(context.coordinator.userID, nil)
        context.coordinator.reportPixels?(context.coordinator.userID, 0)
        context.coordinator.userID = userID
        view.reset()
        attach(userID, view.sink)
        view.reportPixels()
    }

    static func dismantleNSView(_ view: VideoHostView, coordinator: Coordinator) {
        // **Cleared, not merely released.** A sink left installed is a display
        // layer being fed after its window has gone, which keeps the whole
        // decode path alive for a tile nobody can see.
        coordinator.attach?(coordinator.userID, nil)
        coordinator.reportPixels?(coordinator.userID, 0)
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.userID = userID
        coordinator.attach = attach
        coordinator.reportPixels = reportPixels
        return coordinator
    }

    @MainActor
    final class Coordinator {
        var userID = UserID(rawValue: 0)
        var attach: ((UserID, (@Sendable (CMSampleBuffer) -> Void)?) -> Void)?
        var reportPixels: ((UserID, Int) -> Void)?
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
        /// Attaches this view's sink again, which empties the stream's
        /// reassembler and asks its sender for a keyframe at once. See
        /// `InboundStreams.setVideoSink`.
        var startOver: (() -> Void)?
        /// The pixels the picture is drawn at — on the screen's own scale —
        /// each time that changes.
        var onPixels: ((Int) -> Void)?
        private var reportedPixels = 0

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
            reportPixels()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            reportPixels()
        }

        /// Only when the count moves: a grid reflows on every resize.
        func reportPixels() {
            let scale = window?.backingScaleFactor ?? 2
            let pixels = Int((bounds.width * scale).rounded() * (bounds.height * scale).rounded())
            guard pixels != reportedPixels else { return }
            reportedPixels = pixels
            onPixels?(pixels)
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
                    // before it will take anything again**, and a decode that
                    // failed leaves it with no reference for the delta frames
                    // behind it. Either way the tile would freeze on its last
                    // picture until the sender's own next keyframe — so the
                    // renderer starts over and the sender is asked for one now.
                    switch receiver.enqueueImmediately(ready) {
                    case .enqueued, .cancelledDueToFlush:
                        break
                    case .enqueuedWithDecodeFailures:
                        startOver?()
                    case .cancelledDueToFlushRequiredToResume, .cancelledDueToError:
                        receiver.flush()
                        startOver?()
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
    var session: CaptureSessionHandle?
    /// Mirrored, because a self-view that is not is a self-view people cannot
    /// use to aim. Nobody else sees the mirroring.
    var isMirrored = true

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.show(session, mirrored: isMirrored)
        return view
    }

    func updateNSView(_ view: PreviewHostView, context: Context) {
        view.show(session, mirrored: isMirrored)
    }

    /// The view is going: its preview leaves the camera on the camera's queue
    /// now, rather than when the layer is freed on this thread.
    static func dismantleNSView(_ view: PreviewHostView, coordinator: ()) {
        view.show(nil, mirrored: true)
    }

    /// **The preview joins and leaves the camera only through the handle**,
    /// on the camera's own queue. Bound here on the main thread, it could
    /// land inside the camera's start or stop, which AVFoundation answers with
    /// an exception: the capture bar's crash (issue #22), and the same race
    /// when a call's camera turns off as its tile goes.
    final class PreviewHostView: NSView {
        private var preview: AVCaptureVideoPreviewLayer?
        private var shown: CaptureSessionHandle?
        private var isMirrored = true

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        isolated deinit {
            if let preview, let shown { shown.detach(preview) }
        }

        func show(_ session: CaptureSessionHandle?, mirrored: Bool) {
            guard session != shown else {
                // Only a real change goes to the camera's queue: this runs on
                // every SwiftUI update.
                if mirrored != isMirrored, let preview, let shown {
                    shown.setMirrored(mirrored, on: preview)
                }
                isMirrored = mirrored
                return
            }
            if let preview, let shown {
                preview.removeFromSuperlayer()
                shown.detach(preview)
            }
            shown = session
            preview = nil
            isMirrored = mirrored
            guard let session else { return }
            let layer = AVCaptureVideoPreviewLayer()
            layer.videoGravity = .resizeAspectFill
            layer.frame = bounds
            self.layer?.addSublayer(layer)
            session.attach(layer, mirrored: mirrored)
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
