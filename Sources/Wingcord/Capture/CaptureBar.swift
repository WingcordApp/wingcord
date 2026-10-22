import AppKit
import SwiftUI

// MARK: - The capture bar
//
// docs/CLIPS-PRESENCE.md, D12. A small piece of glass at the foot of the
// screen, laid out like the bar macOS's own ⇧⌘5 opens — what to capture, what
// to record it with, then the act — in Wingcord's vocabulary: the capsule
// segmented control, the call's round switches (quiet off, lit with the
// state's colour on), a red Record. HIG: "Keep HUDs small, and don't let one
// obscure or compete for attention with the content it adjusts" — so it sits
// at the edge, and leaves the screen while it captures.

struct CaptureBar: View {
    @Bindable var controller: CaptureController

    var body: some View {
        HStack(spacing: Spacing.snug) {
            SegmentedPicker(
                options: CaptureTarget.allCases.map { .init($0, $0.title, symbolName: $0.symbolName) },
                selection: $controller.target
            )
            .fixedSize()

            CaptureSwitch(
                symbolName: "video.fill", offSymbolName: "video.slash", label: "Camera", isOn: $controller.usesCamera,
                tint: Palette.presenceOnline, help: "Record the camera beside the screen, as a file of its own."
            )
            CaptureSwitch(
                symbolName: "mic.fill", offSymbolName: "mic.slash", label: "Microphone", isOn: $controller.usesMicrophone,
                tint: Palette.presenceOnline, help: "Record your microphone, as a track of its own."
            )
            CaptureSwitch(
                symbolName: "speaker.wave.2.fill", offSymbolName: "speaker.slash", label: "System Sound",
                isOn: $controller.usesSystemAudio,
                tint: Palette.presenceOnline, help: "Record what the Mac plays, except Wingcord's own — a call stays out."
            )

            Menu {
                Picker("Frame Rate", selection: $controller.framerate) {
                    ForEach(CaptureController.framerates, id: \.self) { rate in
                        Text("\(rate) fps").tag(rate)
                    }
                }
                Divider()
                Button("Open Clips Library") { ClipsWindow.open() }
                Button("Open Clips Folder") {
                    try? FileManager.default.createDirectory(at: ClipLibrary.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ClipLibrary.folder)
                }
            } label: {
                Text("Options")
                    .font(.system(.body, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
            .fixedSize()

            Button("Screenshot", systemImage: "camera.viewfinder", action: controller.screenshot)
                .buttonStyle(.glass)
                .controlSize(.extraLarge)
                .help("Take a picture of the \(controller.target.title.lowercased()) you choose next.")

            // Red glass (Alex, 2026-10-21: "i liked the glass red Record") —
            // the prominent style, which is red while the bar has the
            // keyboard, and the bar takes it when it opens.
            Button("Record", systemImage: "record.circle.fill", action: controller.record)
                .buttonStyle(.glassProminent)
                .tint(Palette.destructive)
                .controlSize(.extraLarge)
                .help("Record the \(controller.target.title.lowercased()) you choose next.")

            Button("Close", systemImage: "xmark", action: controller.hideBar)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
        }
        .padding(Spacing.snug)
        .glassEffect(.regular, in: .capsule)
        .overlay(alignment: .top) {
            if let failure = controller.failure {
                Text(failure)
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .padding(.horizontal, Spacing.snug)
                    .padding(.vertical, Spacing.base)
                    .glassEffect(.regular, in: .capsule)
                    .offset(y: -44)
            }
        }
        .padding(Spacing.base)
    }
}

/// One of the bar's switches: a quiet disc off, lit with the state's colour
/// on — the call's controls' vocabulary (`CallButton`).
private struct CaptureSwitch: View {
    var symbolName: String
    var offSymbolName: String
    var label: String
    @Binding var isOn: Bool
    var tint: Color
    var help: String

    @Environment(\.motion) private var motion

    /// The call's switched-on disc: near-white in a dark room, white in a
    /// light one, so the state's colour reads on it either way.
    private static let litFill = Color.adaptive(dark: NSColor(white: 0.9, alpha: 1), light: .white)

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(symbol: isOn ? symbolName : offSymbolName)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(isOn ? tint : Ink.primary)
                .frame(width: SegmentedPicker<Int>.stripHeight, height: SegmentedPicker<Int>.stripHeight)
                .background {
                    if isOn { Circle().fill(Self.litFill) }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .animation(motion.hover, value: isOn)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The pill's Stop: glass, with the stop in red. **The glyph carries the
/// colour, not the glass** — the pill never takes the keyboard (whatever is
/// being recorded is being typed into), and glass in a window without it
/// draws its tint grey; a glyph's colour holds either way.
private struct CaptureStopButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text("Stop").font(.system(.body, weight: .semibold)).foregroundStyle(Ink.primary)
            } icon: {
                Image(symbol: "stop.fill").foregroundStyle(Palette.destructive)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

/// What the bar becomes while it records: the time, Stop, and throw it away.
struct CaptureRecordingPill: View {
    var controller: CaptureController

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Image(symbol: "record.circle.fill")
                .font(.system(.title3))
                .foregroundStyle(Palette.destructive)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
            if case .recording(let since) = controller.phase {
                Text(since, style: .timer)
                    .font(.system(.title3, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Ink.primary)
                    .accessibilityLabel("Recording")
            } else {
                Text("Saving…")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Ink.primary)
            }
            CaptureStopButton {
                Task { await controller.stopRecording() }
            }
            .disabled(!controller.isRecording)
            Button("Discard", systemImage: "trash", action: controller.discardRecording)
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(!controller.isRecording)
                .help("Stop and throw this recording away.")
        }
        .padding(.leading, Spacing.snug)
        .padding(Spacing.base)
        .glassEffect(.regular, in: .capsule)
        .padding(Spacing.base)
    }
}

// MARK: - The panel they float in

/// A borderless glass panel that never takes the app forward — the bar is
/// used over whatever is being captured.
final class CaptureBarPanel: NSPanel {
    enum Edge { case top, bottom }

    init(content: some View) {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 80),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        // **Always drawn as the key window's.** The panel never takes the
        // app forward — the bar is used over whatever is being captured — and
        // AppKit draws an inactive window's controls faded, which on a HUD
        // reads as everything being disabled.
        let host = NSHostingView(rootView: content.environment(\.controlActiveState, .key))
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    /// Escape, while the panel has the keyboard — the bar closes, as macOS's
    /// own capture bar does.
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// On the display under `point`, centred against `edge`.
    func place(onScreenWith point: NSPoint, edge: Edge) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        let visible = screen.visibleFrame
        let y = edge == .bottom ? visible.minY + 24 : visible.maxY - size.height - 12
        setFrame(CGRect(x: visible.midX - size.width / 2, y: y, width: size.width, height: size.height), display: true)
    }
}
