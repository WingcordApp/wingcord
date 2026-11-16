import AVFoundation
import Testing
@testable import WingcordVoice

/// A preview joins and leaves a camera only on the camera's own queue
/// (issue #22, the capture bar's crash). No camera and no permission needed: a
/// session with no inputs starts, stops and takes previews all the same.
struct CaptureSessionHandleTests {

    private func handle() -> CaptureSessionHandle {
        CaptureSessionHandle(
            session: AVCaptureSession(),
            queue: DispatchQueue(label: "dev.wingcord.tests.camera")
        )
    }

    @Test("A preview joins the session, then leaves it, on the session's queue")
    func joinsAndLeaves() {
        let camera = handle()
        let layer = AVCaptureVideoPreviewLayer()
        camera.attach(layer, mirrored: true)
        camera.queue.sync {}
        #expect(layer.session === camera.session)
        camera.detach(layer)
        camera.queue.sync {}
        #expect(layer.session == nil)
    }

    /// Bound from this thread instead, the same loop threw "stopRunning may
    /// not be called between calls to beginConfiguration and
    /// commitConfiguration" twice in 400 (the probe behind issue #22).
    @Test("Previews coming and going while the camera starts and stops never collide")
    func noCollision() {
        let camera = handle()
        for _ in 0..<400 {
            camera.queue.async {
                camera.session.startRunning()
                camera.session.stopRunning()
            }
            let layer = AVCaptureVideoPreviewLayer()
            camera.attach(layer, mirrored: true)
            camera.detach(layer)
        }
        camera.queue.sync {}
        #expect(!camera.session.isRunning)
    }

    @Test("The same camera is equal whichever value carries it")
    func identity() {
        let camera = handle()
        let again = CaptureSessionHandle(session: camera.session, queue: camera.queue)
        #expect(camera == again)
        #expect(camera != handle())
    }
}
