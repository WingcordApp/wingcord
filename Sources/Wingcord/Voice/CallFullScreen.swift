import AppKit
import AVFoundation
import SwiftUI
import WingcordCore

// MARK: - The call, full screen
//
// Discord's call view in its `FULL_SCREEN` mode: the tiles and the controls on
// the call container's own ground — `var(--black)` — and nothing else.
//
// **Over the workspace and under everything a tile can raise.** It is applied
// before the media viewer, the profiles, the person menu and the Go Live sheet,
// so a profile opened from a tile, or a flyout from the controls, comes up on
// top of it. The surfaces underneath stop drawing their own tiles while it is
// up: one person's video can be attached to one view at a time.
//
// **The controls fade when the pointer rests**, after Discord's own
// `IDLE_TIMEOUT` — two seconds — and the tiles' name chips with them, as its
// `.overlayTitle.idle` does. Moving the pointer brings everything back; resting
// on the controls keeps them.

extension View {
    /// The full-screen call — see `AppModel.enterCallFullScreen()`.
    func presentsCallFullScreen() -> some View {
        modifier(CallFullScreenPresenter())
    }
}

extension EnvironmentValues {
    /// Whether the call is full screen with the pointer at rest, when the
    /// tiles' name chips fade with the controls.
    @Entry var isCallIdle = false
}

private struct CallFullScreenPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content
            .overlay {
                ZStack {
                    if model.isCallFullScreen, let presentation = model.voicePresentation {
                        CallFullScreenView(presentation: presentation)
                            .transition(.opacity)
                    }
                }
                // **In with a fade, out with none — and only this layer.** The
                // animation used to sit on the whole app, so everything the
                // switch changed was animated, removals included: the call
                // view on the way out, and the channel's own tile grid on the
                // way in. A speaking tile breathes its edge on a
                // `repeatForever` animation, and SwiftUI keeps a removed view
                // until its animations end — which that one never does. So the
                // call stayed on screen after leaving full screen, and the
                // grid it replaced stayed too, invisible, taking the clicks
                // (Alex, 2026-10-22: "I can't click almost anything"). Out
                // without an animation, there is nothing to wait for.
                .animation(model.isCallFullScreen ? motion.standard : nil, value: model.isCallFullScreen)
            }
            // The call ended, so there is nothing left to be full screen for.
            .onChange(of: model.connectedVoiceChannelID) { _, channelID in
                if channelID == nil { model.exitCallFullScreen() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
                guard let window = note.object as? NSWindow, window === MainWindow.workspaceWindow else { return }
                model.callFullScreenWindowDidExit()
            }
    }
}

private struct CallFullScreenView: View {
    var presentation: VoicePresentation

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var cameraSession: AVCaptureSession?
    @State private var isIdle = false
    /// Where the pointer last moved, kept out of observation: a full-screen
    /// call hears every move, and none of them is a reason to draw.
    @State private var pointer = PointerActivity()

    /// Discord's `IDLE_TIMEOUT` for the call view.
    private static let idleTimeout = Duration.seconds(2)

    var body: some View {
        VStack(spacing: Spacing.snug) {
            VoiceTileGrid(
                participants: presentation.participants,
                spotlightUserID: presentation.spotlightUserID,
                effects: model.soundboardEffectNames,
                cameraSession: cameraSession,
                selfUserID: model.currentUserID,
                attachVideo: model.attachVideo,
                watch: model.toggleWatchingStream,
                spotlight: model.spotlight
            )
            .environment(\.isCallIdle, isIdle)
            controls
        }
        .padding(Spacing.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
        // A black ground is a dark room, whatever the app's appearance.
        .environment(\.colorScheme, .dark)
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            pointer.lastMove = .now
            if isIdle { isIdle = false }
        }
        .task(id: isIdle) {
            guard !isIdle else { return }
            while !Task.isCancelled {
                let deadline = pointer.lastMove.advanced(by: Self.idleTimeout)
                guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil else { return }
                guard ContinuousClock.now >= pointer.lastMove.advanced(by: Self.idleTimeout) else { continue }
                // Resting on the controls is using them.
                if pointer.isOnControls {
                    pointer.lastMove = .now
                    continue
                }
                isIdle = true
                NSCursor.setHiddenUntilMouseMoves(true)
                return
            }
        }
        .task(id: model.isCameraOn) {
            cameraSession = model.isCameraOn ? await model.cameraSession() : nil
        }
    }

    private var controls: some View {
        CallControlRow(
            presentation: presentation,
            toggleMute: model.toggleVoiceMute,
            toggleDeafen: model.toggleVoiceDeafen,
            toggleCamera: model.toggleCamera,
            toggleScreenShare: model.toggleScreenShare,
            leave: model.leaveVoice
        )
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) { CallFullScreenButton() }
        .onHover { pointer.isOnControls = $0 }
        .opacity(isIdle ? 0 : 1)
        .animation(motion.standard, value: isIdle)
    }
}

/// The pointer's last move over the full-screen call.
private final class PointerActivity {
    var lastMove = ContinuousClock.now
    var isOnControls = false
}

/// Discord's Full Screen / Exit Full Screen: a small round button beside a
/// call's controls. Escape answers it while the call is full screen and
/// nothing is open over it.
struct CallFullScreenButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isFullScreen = model.isCallFullScreen
        let title = isFullScreen ? "Exit Full Screen" : "Full Screen"
        Button {
            if isFullScreen { model.exitCallFullScreen() } else { model.enterCallFullScreen() }
        } label: {
            Image(systemName: isFullScreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .frame(width: Metrics.compactControl, height: Metrics.compactControl)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .background { Circle().fill(Palette.selectionFill) }
        .help(title)
        .accessibilityLabel(Text(title))
        .cancelAction(unless: !isFullScreen || model.isCovered(.callFullScreen))
    }
}
