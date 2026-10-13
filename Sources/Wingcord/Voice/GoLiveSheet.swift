import SwiftUI
import WingcordCore

// MARK: - Share Your Screen
//
// Discord's Go Live, as a layer over the window: a surface showing what will
// be sent, and under it the stream's Frame Rate, Resolution and Share Audio,
// with Go Live at the end. **What to share is picked in the system's own
// picker**, which the surface's button raises — there is no list of windows
// drawn here, and a pick needs no Screen Recording permission.
//
// **A layer, not a `.sheet`**, for the events panel's reason: it is raised over
// a call band that is itself in the window, and Escape closes whichever layer
// is on top (`EscapeLayer`).
//
// A solid panel over `Palette.modalScrim` — `ModalPanelBackground` — because a
// modal's content is content. Its controls are the system's glass buttons.

struct GoLiveLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// Wide enough that a 16:9 preview reads as a screen; the panel shrinks
    /// with the window below it.
    private static let width: CGFloat = 960
    private static let height: CGFloat = 700

    var body: some View {
        ZStack {
            if model.isGoLiveSheetOpen {
                Button { model.closeGoLive() } label: {
                    Palette.modalScrim.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .cancelAction(unless: model.isCovered(.goLive))
                .accessibilityLabel(Text("Close"))
                .ignoresSafeArea()
                .transition(.opacity)

                GoLivePanel()
                    .frame(maxWidth: Self.width, maxHeight: Self.height)
                    .padding(Spacing.section)
                    .transition(.materialize)
            }
        }
        .animation(motion.panel, value: model.isGoLiveSheetOpen)
    }
}

/// The panel: a header, the surface, and the stream's choices.
private struct GoLivePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Spacing.group) {
            header
            GoLiveSurface()
            GoLiveFooter()
        }
        .padding(Spacing.group)
        .modalPanel(in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text("Share Your Screen")
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(InkColor.primary)
                if let source = model.screenShareSource {
                    Text(source.name)
                        .font(.system(.callout))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { model.closeGoLive() } label: {
                Image(systemName: "xmark")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(InkColor.solid)
                    .frame(width: Metrics.control, height: Metrics.control)
                    // A region inside the panel, not a body of its own.
                    .background(Circle().fill(Palette.hoverFill))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel(Text("Close"))
        }
    }
}

// MARK: - The surface

/// What will be sent, before it is: the picked source, live, or the button
/// that picks one.
private struct GoLiveSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
        ZStack {
            shape.fill(model.goLivePreview == .previewing ? Color.black : Palette.groupedFill)
            content
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Palette.hairline).allowsHitTesting(false) }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
        .animation(motion.standard, value: model.goLivePreview)
    }

    @ViewBuilder
    private var content: some View {
        switch model.goLivePreview {
        case .empty:
            VStack(spacing: Spacing.margin) {
                Image(systemName: "rectangle.dashed")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Ink.tertiary)
                    .accessibilityHidden(true)
                // Discord's words for what its system picker offers.
                sourceButton("Share a screen, window, or app")
            }
        case .starting:
            ProgressView().controlSize(.large)
        case .previewing:
            VoiceVideoView(userID: UserID(rawValue: 0)) { _, sink in
                model.attachGoLivePreview(sink)
            }
            .accessibilityLabel(Text(model.screenShareSource?.name ?? "Share Your Screen"))
            if isHovering, let source = model.screenShareSource {
                sourceButton(source.changeTitle)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        case .failed(let message):
            VStack(spacing: Spacing.snug) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Ink.tertiary)
                    .accessibilityHidden(true)
                // The system's own words for why it refused.
                Text(message)
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                sourceButton("Share a screen, window, or app")
            }
        }
    }

    private func sourceButton(_ title: String) -> some View {
        Button { model.pickScreenSource() } label: {
            Label(title, systemImage: "rectangle.on.rectangle")
                .font(.system(.body, weight: .semibold))
                .padding(.horizontal, Spacing.tight)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

// MARK: - The choices

/// Frame Rate, Resolution and Share Audio in the middle, Go Live at the end.
private struct GoLiveFooter: View {
    @Environment(AppModel.self) private var model
    @State private var settings = AppSettings.shared
    @State private var isChoosingFrameRate = false
    @State private var isChoosingResolution = false

    var body: some View {
        let gate = model.goLiveGate
        let chosen = gate.admit(settings.goLive)
        ZStack {
            GlassEffectContainer(spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    Button { isChoosingFrameRate.toggle() } label: {
                        Label(chosen.frameRate.label, systemImage: "gauge.with.dots.needle.67percent")
                    }
                    .popover(isPresented: $isChoosingFrameRate, arrowEdge: .bottom) {
                        GoLiveOptionList(title: "Frame Rate") {
                            GoLiveFrameRateRows(settings: chosen, gate: gate) { next in
                                model.updateGoLive(next)
                                isChoosingFrameRate = false
                            }
                        }
                    }
                    .accessibilityLabel(Text("Frame Rate"))
                    .accessibilityValue(Text(chosen.frameRate.label))

                    Button { isChoosingResolution.toggle() } label: {
                        Label(chosen.resolution.label, systemImage: "display")
                    }
                    .popover(isPresented: $isChoosingResolution, arrowEdge: .bottom) {
                        GoLiveOptionList(title: "Resolution") {
                            GoLiveResolutionRows(settings: chosen, gate: gate) { next in
                                model.updateGoLive(next)
                                isChoosingResolution = false
                            }
                        }
                    }
                    .accessibilityLabel(Text("Resolution"))
                    .accessibilityValue(Text(chosen.resolution.label))

                    Button {
                        var next = chosen
                        next.sharesAudio.toggle()
                        model.updateGoLive(next)
                    } label: {
                        Label {
                            Text("Share Audio")
                        } icon: {
                            Image(systemName: chosen.sharesAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                                .foregroundStyle(chosen.sharesAudio ? AnyShapeStyle(.primary) : AnyShapeStyle(Palette.destructive))
                        }
                    }
                    .accessibilityAddTraits(chosen.sharesAudio ? .isSelected : [])
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }

            HStack {
                Spacer(minLength: 0)
                Button("Go Live") { model.goLive() }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.goLivePreview != .previewing)
            }
        }
    }
}

/// A titled list of choices, inside a flyout. No material: the popover's own
/// glass is the body — §4.9.
struct GoLiveOptionList<Rows: View>: View {
    var title: String
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(spacing: 0) {
            FlyoutSectionHeader(title: title)
            rows
        }
        .padding(.bottom, Spacing.tight)
        .frame(width: 200)
    }
}

// MARK: - Discord's choices, as rows

/// Discord's Frame Rate choices.
///
/// **Gated the way Discord's menu gates them**: a frame rate is offered at the
/// resolution already chosen (its `useStreamSettingsItems`), and one the
/// account and server do not allow is drawn locked rather than offered and
/// refused.
struct GoLiveFrameRateRows: View {
    var settings: GoLiveSettings
    var gate: GoLiveGate
    var choose: (GoLiveSettings) -> Void

    var body: some View {
        ForEach(StreamFrameRate.allCases, id: \.self) { rate in
            let isAllowed = gate.allows(settings.resolution, rate)
            FlyoutRow(
                title: rate.label,
                accessory: isAllowed ? .tick(rate == settings.frameRate) : .locked,
                isEnabled: isAllowed,
                isSelected: rate == settings.frameRate
            ) {
                var next = settings
                next.frameRate = rate
                choose(next)
            }
        }
    }
}

/// Discord's Resolution choices, offered at the frame rate already chosen.
struct GoLiveResolutionRows: View {
    var settings: GoLiveSettings
    var gate: GoLiveGate
    var choose: (GoLiveSettings) -> Void

    var body: some View {
        ForEach(StreamResolution.allCases, id: \.self) { resolution in
            let isAllowed = gate.allows(resolution, settings.frameRate)
            FlyoutRow(
                title: resolution.label,
                accessory: isAllowed ? .tick(resolution == settings.resolution) : .locked,
                isEnabled: isAllowed,
                isSelected: resolution == settings.resolution
            ) {
                var next = settings
                next.resolution = resolution
                choose(next)
            }
        }
    }
}
