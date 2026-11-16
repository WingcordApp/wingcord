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
//
// **Everything that touches the session runs on `queue`**: the configuration,
// the start, the recording, the stop, and (through `handle`) the bubble's
// preview. Configuring here and starting there, with the bubble binding its
// preview on the main thread in between, is what crashed the capture bar
// (issue #22): see `CaptureSessionHandle`.

public final class CameraTake: NSObject, @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Capture")

    public enum Failure: Error, LocalizedError, Sendable {
        case noCamera
        case denied
        case couldNotStart(String)

        public var errorDescription: String? {
            switch self {
            case .noCamera: "There is no camera to record."
            case .denied: "Wingcord isn\u{2019}t allowed to use the camera. Turn it on in System Settings \u{203A} Privacy & Security \u{203A} Camera."
            case .couldNotStart(let reason): "The camera could not start: \(reason)"
            }
        }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "dev.wingcord.capture.camera", qos: .userInitiated)
    private let started = Mutex<Double?>(nil)
    private let finished = Mutex<CheckedContinuation<URL?, Never>?>(nil)

    /// The camera, for the bubble's preview.
    public var handle: CaptureSessionHandle { CaptureSessionHandle(session: session, queue: queue) }

    /// When the camera's file began, on the host clock.
    public var startTime: Double? { started.withLock { $0 } }

    /// Opens the camera — `deviceID`, or the system's default — and starts it,
    /// so the bubble can show it before anything is recorded. Answers once the
    /// camera runs.
    ///
    /// Asks for the camera first, as the switch that calls this is the moment
    /// it is needed (HIG: ask when people use the feature).
    public func open(deviceID: String?) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw Failure.denied }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                continuation.resume(with: Result { try run(deviceID: deviceID) })
            }
        }
    }

    /// The open, on `queue`: the device in, the file output on, then the start.
    private func run(deviceID: String?) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw Failure.noCamera }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw Failure.couldNotStart(error.localizedDescription)
        }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        // 1080p where the camera has it, its best where it doesn't (an older
        // USB camera). The input goes in first, at the session's default
        // preset: setting 1080p before it, as this once did, kept such a
        // camera out of the session, and the bubble and the file stayed black.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        session.commitConfiguration()
        session.startRunning()
    }

    /// Starts writing the camera to `url`, once it runs.
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
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard output.isRecording else { return continuation.resume(returning: nil) }
                finished.withLock { $0 = continuation }
                output.stopRecording()
            }
        }
    }

    /// Closes the camera, after anything already asked of it.
    public func close() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
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
