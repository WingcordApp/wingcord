import AppKit
import CoreText
import WingcordCore

/// Resolves the eleven display-name faces, registering each on first use.
///
/// **Lazily, one at a time, and never at launch.** `CTFontManagerRegisterFontsForURL`
/// reads and parses the file and the face then stays resident; eleven of them is
/// 2.2 MB of I/O and residency for a feature that most sessions never draw once.
/// Nearly every profile opened has no style at all, and the ones that do name a
/// single face.
///
/// **`ATSApplicationFontsPath` cannot do this job**, which is the trap this type
/// exists to avoid. That Info.plist key registers a directory inside the *main*
/// bundle's Resources, and SwiftPM puts declared resources in a nested
/// `Wingcord_Wingcord.bundle` that the key never looks into. A build that relies
/// on it gets the system face everywhere and no error at all.
///
/// A face that fails to resolve is remembered as failed, so a missing file costs
/// one attempt rather than one per repaint.
@MainActor
enum DisplayNameFontRegistry {

    private enum State {
        case available
        case unavailable
    }

    private static var state: [DisplayNameFont: State] = [:]

    /// Resolved faces, keyed by face and size.
    ///
    /// **Because the painted canvases ask per row per repaint.** A roster is
    /// five hundred rows and the transcript is every author on screen;
    /// `NSFont(name:size:)` is a descriptor lookup each time, for an answer that
    /// cannot change while the app is running. Two sizes and twelve faces is a
    /// bounded table that fills in the first frame and never grows again.
    private struct FaceKey: Hashable {
        let face: DisplayNameFont
        let size: CGFloat
    }
    private static var faces: [FaceKey: NSFont] = [:]

    /// The face at a size, or nil for the default and for anything that would
    /// not load. **Nil is a normal answer** — the caller draws the app's own
    /// face rather than nothing.
    static func font(_ face: DisplayNameFont, size: CGFloat) -> NSFont? {
        guard let postScriptName = face.postScriptName else { return nil }

        let key = FaceKey(face: face, size: size)
        if let cached = faces[key] { return cached }

        switch state[face] {
        case .available:
            let font = NSFont(name: postScriptName, size: size)
            faces[key] = font
            return font
        case .unavailable:
            return nil
        case nil:
            // Asked for before registering: a face the reader has installed
            // themselves resolves with no file work at all, and the lookup is
            // cheap enough to be worth trying first.
            if let installed = NSFont(name: postScriptName, size: size) {
                state[face] = .available
                faces[key] = installed
                return installed
            }
            guard register(face), let loaded = NSFont(name: postScriptName, size: size) else {
                state[face] = .unavailable
                return nil
            }
            state[face] = .available
            faces[key] = loaded
            return loaded
        }
    }

    private static func register(_ face: DisplayNameFont) -> Bool {
        guard
            let fileName = face.fileName,
            let url = Bundle.module.url(
                forResource: fileName,
                withExtension: "ttf",
                subdirectory: "Fonts"
            )
        else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
