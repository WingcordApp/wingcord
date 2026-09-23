import SwiftUI
import WingcordVoice

// MARK: - What you can do while you are in a call
//
// A cluster of glass bodies inside a `GlassEffectContainer`, which is what lets
// them merge as they come near each other rather than sitting as separate
// panes with seams between them.
//
// **Every control inside a capsule is a REGION, never a second glass body.**
// §4: stacking `.glassEffect` on something already inside a glass capsule gives
// the inner one the outer one's blurred output to sample rather than the content
// behind the window, so it renders as a flat lighter disc and the whole cluster
// loses its depth. A tinted fill inherits the capsule's material and reads as
// part of it — which is exactly how the now bar's three controls are built.
struct VoiceControlBar: View {
    var presentation: VoicePresentation
    var isCompact = false
    /// Whether the ground behind the bar is a picture rather than the reading
    /// surface.
    ///
    /// **It decides the material, and the app's own rule decides it for us**:
    /// `.regular` over a reading surface, `.clear` wherever there is media or a
    /// lit ground behind the chrome — a server banner, a photograph, a video
    /// frame. A game is the most lit ground there is, and the overlay's first
    /// capture showed exactly what the wrong answer looks like: the toolbar read
    /// as four flat dark pills sitting on the screen rather than as glass
    /// floating over it.
    var isOverMedia = false
    /// Whether the input, output and camera controls carry a chevron that opens
    /// the device list.
    ///
    /// Off everywhere but the overlay, and that is not an oversight: in the
    /// window the same lists are two clicks away in Settings › Voice & Video,
    /// where they have room for a level meter and a test tone. Over a game there
    /// is no second surface to send anybody to.
    var showsDeviceMenus = false

    var toggleMute: () -> Void = {}
    var toggleDeafen: () -> Void = {}
    var toggleCamera: () -> Void = {}
    var toggleScreenShare: () -> Void = {}
    var leave: () -> Void = {}

    @Environment(\.motion) private var motion
    @Namespace private var cluster
    /// **Local, not a flag on the store.** There is one control cluster on
    /// screen at a time but three places that build one — the channel stage,
    /// the conversation panel and the HUD — and a shared flag would ask all
    /// three to present at once. §2's rule is about a presentation written into
    /// a list *row*; a control bar is one item, evaluated once, and it is the
    /// only place a popover can point at the button that opened it.
    @State private var isSoundboardOpen = false

    var body: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: isCompact ? Spacing.tight : Spacing.base) {
                // Mute and deafen live in one capsule because they are one
                // decision made twice — "can I be heard" and "can I hear" — and
                // separating them puts two identical discs side by side with no
                // relationship the eye can read.
                capsule {
                    VoiceControl(
                        systemImage: presentation.isMuted ? "mic.slash.fill" : "mic.fill",
                        label: presentation.isMuted ? "Unmute" : "Mute",
                        isActive: presentation.isMuted,
                        accent: Palette.destructive,
                        isCompact: isCompact,
                        action: toggleMute
                    )
                    if showsDeviceMenus { VoiceDeviceChevron(kind: .input, isCompact: isCompact) }
                    VoiceControl(
                        systemImage: presentation.isDeafened ? "headphones.slash" : "headphones",
                        label: presentation.isDeafened ? "Undeafen" : "Deafen",
                        isActive: presentation.isDeafened,
                        accent: Palette.destructive,
                        isCompact: isCompact,
                        action: toggleDeafen
                    )
                    if showsDeviceMenus { VoiceDeviceChevron(kind: .output, isCompact: isCompact) }
                }

                capsule {
                    VoiceControl(
                        systemImage: presentation.isCameraOn ? "video.fill" : "video.slash.fill",
                        label: presentation.isCameraOn ? "Turn Off Camera" : "Turn On Camera",
                        isActive: presentation.isCameraOn,
                        accent: Palette.accent,
                        isCompact: isCompact,
                        action: toggleCamera
                    )
                    if showsDeviceMenus { VoiceDeviceChevron(kind: .camera, isCompact: isCompact) }
                    VoiceControl(
                        systemImage: "rectangle.inset.filled.on.rectangle",
                        label: presentation.isScreenSharing ? "Stop Sharing" : "Share Screen",
                        isActive: presentation.isScreenSharing,
                        accent: Palette.presenceOnline,
                        isCompact: isCompact,
                        action: toggleScreenShare
                    )
                    VoiceControl(
                        systemImage: "music.note.list",
                        label: "Soundboard",
                        isActive: isSoundboardOpen,
                        accent: Palette.accent,
                        isCompact: isCompact,
                        action: { isSoundboardOpen.toggle() }
                    )
                    // **On the button, which is the only place a popover can
                    // point at the control that opened it.** Its contents are
                    // built only while it is presented, which keeps the catalog
                    // read out of the bar's own body — the bar is evaluated
                    // every time somebody starts talking, and the picker is
                    // opened a few times a session.
                    .popover(isPresented: $isSoundboardOpen, arrowEdge: .top) {
                        SoundboardPickerContainer { isSoundboardOpen = false }
                    }
                }

                leaveButton
            }
        }
        .animation(motion.glassMorph, value: presentation.isCameraOn)
        .animation(motion.glassMorph, value: presentation.isScreenSharing)
    }

    /// One glass body holding several regions.
    private func capsule(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, Spacing.tight + 1)
            .padding(.vertical, Spacing.tight)
            // See `isOverMedia`. `.interactive()` in both cases: it is what
            // produces the native pointer-down highlight and lensing, and it is
            // also how this bar satisfies "respond on press, never on release"
            // for free.
            .glassEffect(
                isOverMedia ? .clear.interactive() : .regular.interactive(),
                in: .capsule
            )
    }

    /// The one emphasised control, and it is destructive.
    ///
    /// A surface where three controls are tinted has no emphasis at all, so
    /// this is the only tint in the cluster — and it carries a word rather than
    /// a glyph alone, because leaving a call is the one action here that cannot
    /// be undone by pressing the same button again.
    private var leaveButton: some View {
        Button(action: leave) {
            HStack(spacing: Spacing.tight + 2) {
                Image(systemName: "phone.down.fill")
                    .font(.system(.subheadline, weight: .semibold))
                if !isCompact {
                    Text("Leave")
                        .font(.system(.subheadline, weight: .semibold))
                }
            }
            .foregroundStyle(InkColor.primary)
            .frame(height: controlSide)
            .padding(.horizontal, isCompact ? Spacing.snug : Spacing.margin)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .emphasisChrome(Palette.destructive)
        .help("Leave the call")
        .accessibilityLabel(Text("Leave the call"))
    }

    private var controlSide: CGFloat {
        isCompact ? Metrics.compactControl : Metrics.control + 4
    }
}

// MARK: - One control

/// A region inside the cluster's material: a fill and a glyph, with no material
/// of its own.
///
/// The hover and active states are changes to that fill, which is the only way
/// to light a control inside glass without stacking a second body on the first.
struct VoiceControl: View {
    var systemImage: String
    var label: String
    var isActive: Bool
    var accent: Color
    var isCompact: Bool
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(isCompact ? .footnote : .subheadline, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(accent) : AnyShapeStyle(Ink.primary))
                .frame(width: side, height: side)
                .background {
                    Circle().fill(fill)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.standard, value: isActive)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }

    private var side: CGFloat {
        isCompact ? Metrics.compactControl : Metrics.control + 4
    }

    private var fill: Color {
        if isActive { return accent.opacity(0.22) }
        return isHovering ? voiceControlHovered : .clear
    }
}

// MARK: - The connection, said in one line

/// What the HUD and the overlay put above the tiles.
///
/// **Not a bar of five bars.** A call's quality is loss and jitter, and a
/// signal-strength metaphor borrowed from a phone says nothing about a path that
/// is fast and lossy. The grade is a colour and a sentence.
struct VoiceQualityLine: View {
    var quality: VoiceQuality
    var channelName: String
    var guildName: String?

    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: symbol)
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 0) {
                Text(quality.label)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(tint)
                Text(guildName.map { "\(channelName) / \($0)" } ?? channelName)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            // **A separate glyph, because it answers a separate question.** The
            // waveform says how well the call is carrying; this says who else
            // can hear it. Folding the two into one symbol would mean a poor
            // connection and an unencrypted one looked alike.
            Image(systemName: encryptionSymbol)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(encryptionTint)
                .contentTransition(.symbolEffect(.replace))
                .help(encryptionDescription)
                .accessibilityLabel(encryptionDescription)
        }
        .animation(motion.standard, value: quality.grade)
        .animation(motion.standard, value: quality.encryption)
        .accessibilityElement(children: .combine)
    }

    /// The two derivations that carry the claim, reachable from
    /// `VoiceEncryptionIndicatorTests` — a glyph and a sentence are exactly the
    /// kind of thing that can be wrong while looking fine.
    var encryptionSymbolForTesting: String { encryptionSymbol }
    var encryptionDescriptionForTesting: String { encryptionDescription }

    private var encryptionSymbol: String {
        switch quality.encryption {
        case .endToEnd: "lock.shield.fill"
        case .establishing: "lock.shield"
        // Not an empty slot: an absent glyph reads as "nothing to say", and the
        // thing being said is that the server can hear this call.
        case .transportOnly: "lock.open"
        }
    }

    private var encryptionTint: Color {
        switch quality.encryption {
        case .endToEnd: Palette.presenceOnline
        case .establishing: InkColor.secondary
        case .transportOnly: Palette.presenceIdle
        }
    }

    private var encryptionDescription: String {
        switch quality.encryption {
        case .endToEnd(let code):
            // The code is the whole point of showing one: two people compare it
            // out loud and know nobody is relaying between them.
            "End-to-end encrypted. Verification code \(Self.spaced(code))"
        case .establishing:
            "Setting up end-to-end encryption"
        case .transportOnly:
            "Encrypted to Discord's servers only, not end to end"
        }
    }

    /// The thirty digits in groups of five, which is how they are meant to be
    /// read aloud — an unbroken run is one nobody can compare without losing
    /// their place.
    private static func spaced(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 5).map { offset in
            let start = code.index(code.startIndex, offsetBy: offset)
            let end = code.index(start, offsetBy: min(5, code.count - offset))
            return String(code[start..<end])
        }.joined(separator: " ")
    }

    private var symbol: String {
        switch quality.grade {
        case .connecting: "arrow.triangle.2.circlepath"
        case .good: "waveform"
        case .fair: "waveform.badge.exclamationmark"
        case .poor: "waveform.slash"
        }
    }

    private var tint: Color {
        switch quality.grade {
        case .connecting: Palette.presenceIdle
        case .good: Palette.presenceOnline
        case .fair: Palette.presenceIdle
        case .poor: Palette.destructive
        }
    }
}

// MARK: - The device chevron

/// The little chevron beside the microphone, the headphones and the camera.
///
/// **A region inside the cluster's material, never a second glass body** — §4
/// rule 2, the same contract `VoiceControl` is built on. It is narrow rather
/// than square, because it belongs to the control on its left and a second
/// full-width disc beside that control would read as two buttons of equal
/// weight.
///
/// **The list is read when the popover opens and at no other time.** Building it
/// in the bar's own body would be three CoreAudio enumerations and an
/// `AVCaptureDevice` discovery session on every evaluation — and this bar is
/// evaluated every time somebody in the call starts or stops talking. The
/// soundboard button one group over makes the same argument in the same words.
struct VoiceDeviceChevron: View {
    enum Kind {
        case input
        case output
        case camera

        var title: String {
            switch self {
            case .input: "Microphone"
            case .output: "Output"
            case .camera: "Camera"
            }
        }
    }

    var kind: Kind
    var isCompact: Bool

    @Environment(AppModel.self) private var model
    @State private var isOpen = false
    @State private var isHovering = false
    @Environment(\.motion) private var motion

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: isCompact ? 7 : 8, weight: .black))
                .foregroundStyle(Ink.secondary)
                .frame(width: isCompact ? 12 : 14, height: side)
                .background { Capsule().fill(isHovering ? voiceControlHovered : .clear) }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VoiceDeviceList(kind: kind) { isOpen = false }
                // The list carries its own ground; a second material here would
                // be glass on glass.
                .presentationBackground(.clear)
        }
        .help("Choose a \(kind.title.lowercased())")
        .accessibilityLabel(Text("Choose a \(kind.title.lowercased())"))
    }

    private var side: CGFloat {
        isCompact ? Metrics.compactControl : Metrics.control + 4
    }
}

/// What the chevron opens: the machine's devices, and which one is in use.
///
/// **"System default" is a row, not the absence of one.** A preference of nil
/// means "follow whatever the Mac is doing", which is a different answer from
/// naming the device the Mac happens to be using right now — unplug a headset
/// and the two diverge. A list that only named devices could not express it.
private struct VoiceDeviceList: View {
    var kind: VoiceDeviceChevron.Kind
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kind.title.uppercased())
                .font(Typeface.categoryHeader)
                .foregroundStyle(Ink.tertiary)
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, Spacing.base)

            row(title: "System default", isSelected: selection == nil) { choose(nil) }
            ForEach(devices, id: \.id) { device in
                row(title: device.name, isSelected: selection == device.id) {
                    choose(device.id)
                }
            }
        }
        .padding(.bottom, Spacing.base)
        .frame(width: 240, alignment: .leading)
        // No material of its own: the popover's glass is the body — §4.9.
    }

    /// One device. Resolved to `(id, name)` here so the three kinds share one
    /// row rather than growing three copies of it.
    private var devices: [(id: String, name: String)] {
        switch kind {
        case .input:
            AudioDeviceCatalog.inputs().map { ($0.uniqueID, $0.name) }
        case .output:
            AudioDeviceCatalog.outputs().map { ($0.uniqueID, $0.name) }
        case .camera:
            CameraCapture.devices().map { ($0.id, $0.name) }
        }
    }

    private var selection: String? {
        switch kind {
        case .input: settings.voiceInputDeviceID
        case .output: settings.voiceOutputDeviceID
        case .camera: settings.cameraDeviceID
        }
    }

    /// Writes the choice and hands it to a call already running.
    ///
    /// **Applied live, which is the whole reason this control is on the
    /// overlay.** A device picker that only takes effect on the next call is a
    /// picker nobody would open mid-game.
    private func choose(_ id: String?) {
        switch kind {
        case .input: settings.voiceInputDeviceID = id
        case .output: settings.voiceOutputDeviceID = id
        case .camera: settings.cameraDeviceID = id
        }
        model.voicePreferencesChanged()
        dismiss()
    }

    private func row(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.rowMinHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A voice control under the pointer: light on a dark room's glass, shade on a
/// light one's.
private let voiceControlHovered = Color.relative(dark: 0.14, light: 0.10)
