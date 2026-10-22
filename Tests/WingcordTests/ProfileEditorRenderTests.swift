import AppKit
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// Phase 9's editor surfaces over the demo's own model, drawn offscreen — with
/// `WINGCORD_RENDER_DIR` set each is written there as a PNG to look at; without
/// it they still lay out, which catches one that collapses. Glass does not
/// composite offscreen, so glass reads darker here than on screen — and a
/// `.glassProminent` button blanks the whole picture, so the save bar and the
/// cropper only lay out here; they are looked at on screen.
@MainActor
@Suite("Profile editor renders")
struct ProfileEditorRenderTests {

    private func setUp(scope: ProfileEditor.Scope = .account) -> (AppModel, ProfileEditor) {
        let model = AppModel()
        DemoFixtures.populate(model)
        let me = model.currentUserID!
        let base = model.profileEditBase(for: scope, userID: me)!
        let editor = ProfileEditor(profile: base, widgets: [], scope: scope, accountName: base.displayName)
        return (model, editor)
    }

    @Test("Wingcord's colour picker")
    func colourPicker() throws {
        var colour: UInt32 = 0xF0_6E_B3
        let binding = Binding(get: { colour }, set: { colour = $0 })
        let size = try render(
            PlayfulColourPicker(colour: binding, fromArtwork: [0x89_86_7D, 0xD5_D4_D3, 0x2A_2B_2A], title: "Primary"),
            named: "colour-picker"
        )
        #expect(size.width >= PlayfulColourPicker.width)
        #expect(size.height > 300)
    }

    @Test("The colour flyout, with and without a theme")
    func colourFlyout() throws {
        let (model, editor) = setUp()
        let size = try render(ProfileColourFlyout(editor: editor).environment(model), named: "colour-flyout")
        #expect(size.height > 300)
    }

    @Test("The save bar, and its failure")
    func saveBar() throws {
        let (_, editor) = setUp()
        editor.bio = "changed"
        let size = try render(ProfileEditBar(editor: editor, save: {}), named: "save-bar")
        #expect(size.width > 300)
    }

    @Test("The name style and picture flyouts")
    func flyouts() throws {
        let (model, editor) = setUp()
        let style = try render(DisplayNameStyleFlyout(editor: editor).environment(model), named: "flyout-name-style")
        #expect(style.width >= 380)
        let picture = try render(PictureFlyout(kind: .banner, editor: editor, close: {}).environment(model), named: "flyout-banner")
        #expect(picture.height > 100)
    }

    @Test("The avatar flyout, with Choose GIF beside Upload Image")
    func avatarFlyout() throws {
        let (model, editor) = setUp()
        model.gifMosaic = DemoGIFs.all.prefix(4).compactMap(\.previewURL)
        model.gifMosaicRequested = true
        let size = try render(
            PictureFlyout(kind: .avatar, editor: editor, close: {}).environment(model).environment(ProfileFlyouts()),
            named: "flyout-avatar"
        )
        #expect(size.height > 200)
    }

    @Test("The rail, for the account and for a locked server")
    func rail() throws {
        let (model, editor) = setUp()
        let flyouts = ProfileFlyouts()
        let account = try render(
            ProfileEditRail(editor: editor, profile: editor.applied(to: editor.base), scopes: [.main], selectScope: { _ in }, collapse: {})
                .environment(model).environment(flyouts).environment(editor)
                .frame(height: 900),
            named: "rail-account"
        )
        #expect(account.width >= ProfileEditRail.width)

        guard let guildID = model.guilds.keys.first else { return }
        let (_, serverEditor) = setUp(scope: .guild(guildID))
        let server = try render(
            ProfileEditRail(
                editor: serverEditor, profile: serverEditor.applied(to: serverEditor.base),
                scopes: [.main, ProfileEditScope(scope: .guild(guildID), title: "REA: Reverse Engineering Archive")],
                selectScope: { _ in }, collapse: {}
            )
            .environment(model).environment(flyouts).environment(serverEditor)
            .frame(height: 900),
            named: "rail-server"
        )
        #expect(server.width >= ProfileEditRail.width)
    }

    @Test("Edit Image: a wide picture cropped to an avatar and a banner")
    func cropper() throws {
        let image = try #require(Self.sampleImage(width: 1600, height: 900))
        for (name, shape) in [("crop-avatar", PictureCrop.Shape.avatar), ("crop-banner", .banner)] {
            let size = try render(
                PictureCropView(shape: shape, preview: image, apply: { _ in }, skip: {}).frame(width: 308),
                named: name
            )
            #expect(size.height > 150)
        }
        // And the cut itself: a PNG of the crop's own size.
        let data = try #require(PictureFile.encodePNG(image))
        let crop = PictureCrop(shape: .avatar, imageSize: CGSize(width: 1600, height: 900), viewport: CGSize(width: 240, height: 240))
        let cut = try #require(PictureFile.cropped(.png(data), to: crop))
        let frame = try #require(PictureFile.firstFrame(cut))
        #expect(frame.width == 900 && frame.height == 900)
    }

    /// A gradient with a bright square in it, so a crop can be seen.
    static func sampleImage(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colours = [CGColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1), CGColor(red: 0.95, green: 0.4, blue: 0.6, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: width / 2 - 120, y: height / 2 - 120, width: 240, height: 240))
        return context.makeImage()
    }

    private func render(_ view: some View, named name: String, width: CGFloat? = nil) throws -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width).padding(12).background(Color(white: 0.11)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"],
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return host.bounds.size }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        return host.bounds.size
    }
}
