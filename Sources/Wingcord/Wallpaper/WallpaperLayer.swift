import AppKit
import AVFoundation
import SwiftUI

/// The window's ground: the theme, the desktop, or the wallpaper the shown
/// conversation wears — one layer under the whole window.
///
/// **The next picture is loaded before anything fades** (Noodle's rule), so a
/// conversation switch never flashes the theme between two photographs: the
/// outgoing wallpaper stays up until the incoming one has a bitmap, then the
/// two cross-fade. The theme's own ground is always underneath, so a fade to or
/// from a picture passes through the room rather than through black.
struct WallpaperLayer: View {
    @State private var store = WallpaperStore.shared
    @State private var frost = WallpaperFrost.shared
    @State private var displayed: ShownWallpaper?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let wanted = store.shown
        ZStack {
            Color.clear.themeGroundOnly()
            if let displayed {
                scene(displayed)
                    .id(displayed.id)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: wanted) { await show(wanted) }
        // The dark room follows the picture, not the conversation: a
        // conversation on the theme puts the reader's own room back.
        .onChange(of: forcesDark(wanted), initial: true) { _, forces in
            ThemeStore.shared.setWallpaperForcesDark(forces)
        }
    }

    private func forcesDark(_ wallpaper: Wallpaper) -> Bool {
        store.forcesDarkAppearance && wallpaper.source.isPicture
    }

    // MARK: Loading

    private func show(_ wallpaper: Wallpaper) async {
        guard displayed?.wallpaper != wallpaper else { return }
        let poster = await WallpaperMedia.poster(of: wallpaper.source, blur: wallpaper.blur)
        guard !Task.isCancelled else { return }
        let next = ShownWallpaper(wallpaper: wallpaper, poster: poster)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
            displayed = next
        }
        // The bubbles' frost: the same picture, small and blurred hard. After
        // the fade has begun, so the switch never waits on it.
        let frostImage: CGImage? = switch wallpaper.source {
        case .preset(let preset): await Self.presetFrost(preset)
        default: wallpaper.source.isPicture ? await WallpaperMedia.frost(of: wallpaper.source) : nil
        }
        guard !Task.isCancelled else { return }
        frost.update(image: frostImage, preset: presetOf(wallpaper), veil: veilAmount(wallpaper))
    }

    /// A built-in scene has no file to decode, so its frost is drawn: the same
    /// view rendered small, then blurred off the main actor.
    private static func presetFrost(_ preset: WallpaperPreset) async -> CGImage? {
        let renderer = ImageRenderer(content: PresetScene(preset: preset).frame(width: 768, height: 480))
        guard let image = renderer.cgImage else { return nil }
        return await Task.detached(priority: .userInitiated) {
            WallpaperMedia.blurred(image, fraction: WallpaperMedia.frostFraction)
        }.value
    }

    private func presetOf(_ wallpaper: Wallpaper) -> WallpaperPreset? {
        if case .preset(let preset) = wallpaper.source { return preset }
        return nil
    }

    // MARK: Drawing

    @ViewBuilder
    private func scene(_ shown: ShownWallpaper) -> some View {
        switch shown.wallpaper.source {
        case .theme:
            Color.clear
        case .desktop:
            DesktopThroughWindow()
                .ignoresSafeArea()
        case .preset(let preset):
            PresetScene(preset: preset)
                .overlay { veil(shown.wallpaper) }
                .ignoresSafeArea()
        case .image, .video, .system:
            // **In an overlay on a clear view, never as a child that sizes
            // anything.** An aspect-filled image reports the size it fills to —
            // taller than the window for a landscape photograph in a tall
            // window — and as a sibling it grew the shell past the window's foot.
            Color.clear
                .overlay {
                    if let poster = shown.poster {
                        Image(decorative: poster, scale: 1, orientation: .up)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .overlay {
                    if shown.wallpaper.source.isVideo, let url = shown.wallpaper.source.fileURL {
                        WallpaperVideo(url: url, plays: !reduceMotion)
                    }
                }
                .clipped()
                .overlay { veil(shown.wallpaper) }
                .ignoresSafeArea()
        }
    }

    /// Black over the picture: the reader's dim, raised by Reduce Transparency
    /// and Increase Contrast — both ask for the text on top to win.
    private func veil(_ wallpaper: Wallpaper) -> some View {
        Color.black.opacity(veilAmount(wallpaper))
    }

    private func veilAmount(_ wallpaper: Wallpaper) -> Double {
        var amount = wallpaper.dim
        if reduceTransparency { amount = max(amount, 0.6) }
        if contrast == .increased { amount = max(amount, 0.45) }
        return amount
    }
}

/// What the layer is drawing: the wallpaper and its decoded still.
private struct ShownWallpaper: Identifiable {
    let id = UUID()
    let wallpaper: Wallpaper
    let poster: CGImage?
}

/// A built-in scene: a diagonal gradient with a large blurred light — Noodle's
/// recipe, drawn rather than shipped as artwork.
struct PresetScene: View {
    var preset: WallpaperPreset

    var body: some View {
        GeometryReader { proxy in
            let colors = preset.colors
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse()
                    .fill(colors[1].opacity(0.5))
                    .frame(width: proxy.size.width * 1.4, height: proxy.size.height * 1.1)
                    .rotationEffect(.degrees(-35))
                    .offset(x: proxy.size.width * 0.35)
                    .blur(radius: 50)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }
}

/// The desktop, blurred through the window — the wallpaper for a reader who
/// wants the app to sit in their own.
private struct DesktopThroughWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - The frost the bubbles sample

/// The shown wallpaper's frosted rendition, for the transcript's bubbles
/// (REDESIGN.md R6). One value for the window, published once per change of
/// wallpaper; the canvas peeks at it.
@Observable
@MainActor
final class WallpaperFrost {
    static let shared = WallpaperFrost()

    /// The picture, blurred hard. Nil when the wallpaper is not a picture.
    private(set) var image: CGImage?
    /// The preset scene, which the canvas draws as its own gradient.
    private(set) var preset: WallpaperPreset?
    /// Moves on every change, so a drawn surface keyed on it knows to repaint.
    private(set) var revision: UInt64 = 0
    /// What a coloured name drawn straight on the wallpaper is checked against
    /// — the veiled picture's brightest patch, as a grey — or nil with no
    /// picture up, where the theme's own ground is the answer. See
    /// `AppModel.nameGround`.
    private(set) var nameGround: UInt32?

    /// The display options changed: every surface keyed on the revision draws
    /// its frost again — or stops, under Reduce Transparency.
    func displayOptionsDidChange() {
        revision &+= 1
    }

    func update(image: CGImage?, preset: WallpaperPreset?, veil: Double) {
        let levels = image.map(WallpaperMedia.levels(of:))
        let ground = levels.map { Self.nameGround(levels: $0, veil: veil, isLight: ThemeInk.current.isLight) }
        guard image !== self.image || preset != self.preset || ground != nameGround else { return }
        self.image = image
        self.preset = preset
        // The painter's tints change with it: smoke over a frost, as much as
        // its brightest patch asks for, and a plain lift over the theme's
        // ground.
        BubbleTint.setFrost(levels)
        revision &+= 1
        if ground != nameGround {
            nameGround = ground
            // Names carry their colour inside the transcript's laid-out text.
            PresentationRevision.shared.settingsDidChange()
        }
    }

    /// The grey a coloured name over this picture has to read against.
    ///
    /// **The brightest patch, through the veil — in a dark room capped dark.**
    /// The veil is black at `veil`, which scales the picture's encoded value;
    /// the cap keeps the answer on the dark side, so a name is moved toward a
    /// lighter tint of its own colour, like the white words beside it, and
    /// never flipped dark over a sky. A light room is the mirror: the darkest
    /// patch, floored light.
    nonisolated static func nameGround(levels: FrostLevels, veil: Double, isLight: Bool) -> UInt32 {
        func encoded(_ luminance: Double) -> Double {
            luminance <= 0.0031308 ? luminance * 12.92 : 1.055 * pow(luminance, 1 / 2.4) - 0.055
        }
        let darkCap = encoded(0.12), lightFloor = encoded(0.35)
        let value = isLight
            ? max(encoded(levels.darkest) * (1 - veil), lightFloor)
            : min(encoded(levels.brightest) * (1 - veil), darkCap)
        let channel = UInt32((min(max(value, 0), 1) * 255).rounded())
        return channel << 16 | channel << 8 | channel
    }
}

// MARK: - A looping video

/// A video wallpaper: muted, looping, and still while nobody can see it.
///
/// Adapted from Noodle's `AnimatedWallpaper` (Apache-2.0; THIRD-PARTY-NOTICES.md):
/// an `AVQueuePlayer` under an `AVPlayerLooper` on a layer, paused while the
/// window is occluded or minimised or the app hidden, and never playing under
/// Reduce Motion — the poster underneath is the still.
private struct WallpaperVideo: NSViewRepresentable {
    var url: URL
    var plays: Bool

    func makeNSView(context: Context) -> WallpaperVideoView { WallpaperVideoView() }

    func updateNSView(_ view: WallpaperVideoView, context: Context) {
        view.configure(url: url, plays: plays)
    }

    static func dismantleNSView(_ view: WallpaperVideoView, coordinator: ()) {
        view.stop()
    }
}

@MainActor
final class WallpaperVideoView: NSView {
    private var url: URL?
    private var plays = true
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        CATransaction.commit()
    }

    func configure(url: URL, plays: Bool) {
        self.plays = plays
        if self.url != url {
            stop()
            self.url = url
            let player = AVQueuePlayer()
            player.isMuted = true
            player.volume = 0
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
            self.player = player
            self.playerLayer = playerLayer
            needsLayout = true
        }
        updatePlayback()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePlayback() }
                })
            }
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePlayback() }
                })
            }
        }
        updatePlayback()
    }

    private func updatePlayback() {
        let visible = window?.occlusionState.contains(.visible) == true
            && window?.isMiniaturized == false
            && !NSApp.isHidden
        // Muted again before every play: a resumed player keeps no promise.
        player?.isMuted = true
        player?.volume = 0
        if visible && plays { player?.play() } else { player?.pause() }
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        url = nil
    }
}
