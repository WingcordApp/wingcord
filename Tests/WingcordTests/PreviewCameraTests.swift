import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Discord's Preview Camera and its "Always preview video" (modules 308229,
/// 442353), and whose camera a call asks for whole.
@Suite("Preview Camera")
@MainActor
struct PreviewCameraTests {

    @Test("With Always preview video on, turning the camera on opens the preview")
    func alwaysPreviews() {
        let model = AppModel()
        model.syncedPreferences.alwaysPreviewsVideo = true
        model.toggleCamera()
        #expect(model.isCameraPreviewOpen)
    }

    @Test("Off, the camera switch goes straight to the camera")
    func previewOff() {
        let model = AppModel()
        model.toggleCamera()
        #expect(!model.isCameraPreviewOpen)
    }

    /// Discord's selected participant: a spotlight showing somebody's share is
    /// not their camera.
    @Test("The spotlight is the focused camera, unless it is showing their share")
    func focusedCamera() {
        let model = AppModel()
        let person = UserID(rawValue: 5)
        #expect(model.focusedCameraUserID == nil)
        model.spotlight(person)
        #expect(model.focusedCameraUserID == person)
        model.watchedStreamUserID = person
        #expect(model.focusedCameraUserID == nil)
    }
}
