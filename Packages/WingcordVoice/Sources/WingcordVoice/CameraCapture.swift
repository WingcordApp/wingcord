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

/// A capture session, safe to hand across an isolation boundary.
///
/// `AVCaptureSession` is not `Sendable` and its own documentation is explicit
/// that configuration must be serialised — which this type does, on its capture
/// queue. What a preview layer needs is only to *hold* the session, and that is
/// what the wrapper vouches for.
public struct CaptureSessionHandle: @unchecked Sendable {
    public let session: AVCaptureSession
    public init(_ session: AVCaptureSession) { self.session = session }
}

public final class CameraCapture: NSObject, @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Camera")

    /// A frame, on the capture queue. Never the main actor.
    public var onFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?

    public let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dev.wingcord.camera", qos: .userInitiated)
    private var input: AVCaptureDeviceInput?

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

    /// Whether the user has already granted the camera.
    ///
    /// Asked rather than assumed, because the failure to ask is invisible:
    /// starting a session without authorisation produces a session that runs and
    /// delivers black frames.
    public static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    // MARK: Running

    public func start(deviceID: String?, framerate: Int = 30) async -> Bool {
        guard await Self.requestAccess() else { return false }

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

        guard !session.isRunning else { return true }
        // `startRunning` blocks for as long as the hardware takes to come up —
        // up to a second on an external camera — so it never runs on the actor
        // that is drawing the tile it is about to fill.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // `self`, not `session`: `AVCaptureSession` is not `Sendable` and
            // this type is the thing that vouches for it. Capturing the session
            // directly is the same object crossing the same boundary with
            // nothing standing behind it.
            queue.async { [self] in
                session.startRunning()
                continuation.resume()
            }
        }
        return true
    }

    public func stop() {
        guard session.isRunning else { return }
        queue.async { [self] in session.stopRunning() }
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
