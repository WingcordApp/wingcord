import AVFoundation
import CoreMedia
import Foundation
import OSLog

// MARK: - The camera
//
// `AVCaptureSession` straight into `AVCaptureVideoDataOutput`, at the pixel
// format VideoToolbox's encoder wants. Nothing converts anything: the camera
// produces bi-planar 4:2:0, the encoder takes bi-planar 4:2:0, and the frames
// are IOSurface-backed the whole way — so the path from sensor to network never
// touches a pixel in Swift.
//
// The self-view is `AVCaptureVideoPreviewLayer` on the same session rather than
// a view drawing the frames this class hands out. It is a separate hardware path
// with no round trip through the encoder, which is why the reference clients'
// self-view has no latency and a hand-rolled one always does.

public struct CameraDevice: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Whether the picker should say where it is. A Mac with a built-in camera,
    /// an iPhone on Continuity and a capture card in a dock is an ordinary
    /// setup, and three rows called "Camera" is not a picker.
    public var kind: String
}

/// The call's camera, and the settings' test of it.
///
/// **Everything that touches the session runs on `queue`**: its
/// configuration, the device's frame rate, the start and the stop, and (through
/// `handle`) every preview. That queue is also where frames arrive. See
/// `CaptureSessionHandle` for the crash that rule prevents.
public final class CameraCapture: NSObject, @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Camera")

    /// A frame, on the capture queue. Never the main actor.
    public var onFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dev.wingcord.camera", qos: .userInitiated)
    /// Changed on `queue` only.
    private var input: AVCaptureDeviceInput?

    /// The camera, for a self-view's preview.
    public var handle: CaptureSessionHandle {
        CaptureSessionHandle(session: session, queue: queue)
    }

    public override init() {
        super.init()
        // 720p. Higher costs bitrate the channel does not have and a
        // downscale in the encoder that nobody sees; lower is visibly soft on a
        // tile the size this app draws.
        session.sessionPreset = .hd1280x720
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        // A frame the encoder has not kept up with is a frame worth throwing
        // away. Queueing them instead builds latency that never drains.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
    }

    // MARK: Devices

    public static func devices() -> [CameraDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { device in
            CameraDevice(
                id: device.uniqueID,
                name: device.localizedName,
                kind: label(for: device.deviceType)
            )
        }
    }

    private static func label(for type: AVCaptureDevice.DeviceType) -> String {
        switch type {
        case .builtInWideAngleCamera: "Built-in"
        case .external: "USB"
        case .continuityCamera: "iPhone"
        case .deskViewCamera: "Desk View"
        default: "Camera"
        }
    }


    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    // MARK: Running

    /// Picks the camera and starts it, or switches a running one to another
    /// device. Answers once it runs.
    ///
    /// **All of it on `queue`, in one piece.** It used to configure on
    /// whichever thread called and start on the queue, so two calls close
    /// together (the preview sheet opening as the device changes) could start
    /// the session inside the other's configuration, which AVFoundation answers
    /// with an exception. `startRunning` also blocks for as long as the
    /// hardware takes to come up (up to a second on an external camera), which
    /// is the other reason it never runs on the actor drawing the tile.
    public func start(deviceID: String?, framerate: Int = 30) async -> Bool {
        guard await Self.requestAccess() else { return false }
        return await withCheckedContinuation { continuation in
            // `self`, not `session`: `AVCaptureSession` is not `Sendable` and
            // this type is the thing that vouches for it.
            queue.async { [self] in
                continuation.resume(returning: run(deviceID: deviceID, framerate: framerate))
            }
        }
    }

    /// The start, on `queue`.
    private func run(deviceID: String?, framerate: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { return false }

        session.beginConfiguration()
        if let input { session.removeInput(input) }
        do {
            let next = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(next) else {
                session.commitConfiguration()
                return false
            }
            session.addInput(next)
            input = next
        } catch {
            session.commitConfiguration()
            Self.log.error("camera input failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        session.commitConfiguration()

        // The frame duration is set on the *device*, after it is in the
        // session: a rate configured before the input is added is discarded
        // when the session picks the format.
        if let locked = try? device.lockForConfiguration() {
            _ = locked
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(framerate))
            device.unlockForConfiguration()
        }

        if !session.isRunning { session.startRunning() }
        return true
    }

    /// Stops the camera, after anything already asked of it.
    public func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }
}

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixels, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}
