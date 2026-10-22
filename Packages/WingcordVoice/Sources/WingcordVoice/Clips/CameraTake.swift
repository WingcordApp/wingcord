import AVFoundation
import Foundation
import OSLog
import QuartzCore
import Synchronization

// MARK: - The camera, beside a screen recording
//
// docs/CLIPS-PRESENCE.md, D12. Recorded to its own file — never into the
// screen's picture — so an editor can move it, size it or leave it out. The
// bubble on screen is this session's preview layer, and the screen recording
// leaves that window out.

public final class CameraTake: NSObject, @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Capture")

    public enum Failure: Error, LocalizedError, Sendable {
        case noCamera
        case couldNotStart(String)

        public var errorDescription: String? {
            switch self {
            case .noCamera: "There is no camera to record."
            case .couldNotStart(let reason): "The camera could not start: \(reason)"
            }
        }
    }

    public let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "dev.wingcord.capture.camera", qos: .userInitiated)
    private let started = Mutex<Double?>(nil)
    private let finished = Mutex<CheckedContinuation<URL?, Never>?>(nil)

    /// A handle for the bubble's preview layer.
    public var handle: CaptureSessionHandle { CaptureSessionHandle(session) }

    /// When the camera's file began, on the host clock.
    public var startTime: Double? { started.withLock { $0 } }

    /// Opens the camera — `deviceID`, or the system's default — so the bubble
    /// can show it before anything is recorded.
    public func open(deviceID: String?) throws {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw Failure.noCamera }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .hd1920x1080
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
        } catch {
            throw Failure.couldNotStart(error.localizedDescription)
        }
        queue.async { [self] in session.startRunning() }
    }

    /// Starts writing the camera to `url`.
    public func record(to url: URL) {
        queue.async { [self] in
            if let connection = output.connection(with: .video) {
                output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
            output.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// Stops writing, and hands back the file once it is finished — nil when
    /// nothing was recorded.
    public func finish() async -> URL? {
        guard output.isRecording else { return nil }
        return await withCheckedContinuation { continuation in
            finished.withLock { $0 = continuation }
            queue.async { [self] in output.stopRecording() }
        }
    }

    /// Closes the camera.
    public func close() {
        queue.async { [self] in session.stopRunning() }
    }
}

extension CameraTake: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(
        _ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]
    ) {
        started.withLock { $0 = CACurrentMediaTime() }
    }

    public func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection], error: (any Error)?
    ) {
        if let error { Self.log.warning("capture: camera file: \(error.localizedDescription, privacy: .public)") }
        let continuation = finished.withLock { slot -> CheckedContinuation<URL?, Never>? in
            defer { slot = nil }
            return slot
        }
        // AVFoundation reports a stop it was asked for as an "error" with the
        // file intact; the file is what matters.
        let exists = FileManager.default.fileExists(atPath: outputFileURL.path)
        continuation?.resume(returning: exists ? outputFileURL : nil)
    }
}
