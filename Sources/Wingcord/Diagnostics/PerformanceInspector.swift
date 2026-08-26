import AppKit
import SwiftUI

/// The live performance overlay.
///
/// **It costs nothing while it is off.** The whole view — and the display link
/// behind it — exists only while the setting is on: the modifier's body returns
/// its content untouched otherwise, so there is no hidden view, no timer, and no
/// sampling.
///
/// What it shows is chosen to answer the questions that actually come up:
///
///  - **Frame time and slow-frame count**, against the display's own cadence
///    rather than an assumed 60 Hz — a 120 Hz Mac has half the budget, and
///    that is the machine most likely to show a hitch.
///  - **Physical footprint**, not resident size. Resident size wanders for
///    reasons unrelated to the app.
///  - **What the store is holding**, because "memory is high" is only actionable
///    once you know whether it is transcripts, images, or neither.
struct PerformanceInspector: View {
    @State private var snapshot = PerformanceSnapshot.empty
    @State private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("frame", value: format(snapshot.lastFrameMilliseconds, unit: "ms"), isBad: isFrameSlow)
            row("worst", value: format(snapshot.worstFrameMilliseconds, unit: "ms"), isBad: snapshot.worstFrameMilliseconds > budget * 2)
            row("slow", value: "\(snapshot.slowFrames)/300", isBad: snapshot.slowFrames > 6)
            Divider().padding(.vertical, 2)
            row("memory", value: snapshot.footprintDescription, isBad: snapshot.footprint > 700 * 1_048_576)
            row("channels", value: "\(snapshot.residentChannels)", isBad: false)
            row("messages", value: "\(snapshot.residentMessages)", isBad: snapshot.residentMessages > 2000)
            if snapshot.isScrolling {
                row("state", value: "scrolling", isBad: false)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(Spacing.base)
        .background {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(.black.opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        // Never intercepts a click. An overlay that swallows input is a
        // diagnostic that changes the thing it is diagnosing.
        .allowsHitTesting(false)
        .task {
            // Four samples a second: fast enough to see a hitch land, slow
            // enough that the overlay's own updates are not what the frame timer
            // is measuring.
            while !Task.isCancelled {
                snapshot = PerformanceMonitor.shared.snapshot()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var budget: Double { 1000 / max(snapshot.displayHertz, 1) }

    private var isFrameSlow: Bool {
        snapshot.lastFrameMilliseconds > budget * 1.5
    }

    private func format(_ value: Double, unit: String) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + unit
    }

    private func row(_ label: String, value: String, isBad: Bool) -> some View {
        HStack(spacing: Spacing.base) {
            Text(label)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 58, alignment: .leading)
            Text(value)
                .foregroundStyle(isBad ? Color.orange : .white)
        }
    }
}

extension View {
    /// Attaches the inspector at the window root.
    func showsPerformanceInspector() -> some View {
        modifier(PerformanceInspectorModifier())
    }
}

private struct PerformanceInspectorModifier: ViewModifier {
    @State private var settings = AppSettings.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if settings.showsPerformanceInspector {
                    PerformanceInspector()
                        .padding(Spacing.snug)
                        .transition(.materialize(from: .bottomTrailing))
                }
            }
            .background {
                // The display link needs a real view to attach to, and it is
                // installed only while the inspector is on.
                if settings.showsPerformanceInspector {
                    DisplayLinkAnchor()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// A zero-size view that gives the monitor something to hang a display link on.
private struct DisplayLinkAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Deferred by one turn: the view has no window yet at `makeNSView`, and
        // `displayLink(target:selector:)` needs one to know which display's
        // cadence to follow.
        Task { @MainActor in
            guard view.window != nil else { return }
            PerformanceMonitor.shared.startSampling(in: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// Stopping is not optional: a display link left running ticks at the
    /// refresh rate for the life of the process, which is a battery cost with no
    /// reader.
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        MainActor.assumeIsolated {
            PerformanceMonitor.shared.stopSampling()
        }
    }
}
