import SwiftUI
import WingcordCore

// MARK: - Performance, over the game
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D20). The machine's processor, the game's
// own share of it, graphics, memory and heat — once a second, and only while
// the widget is on screen (`SystemLoadSampler` reads nothing at rest). Off by
// default: Discord's own performance widget is a debug surface.
//
// **Not a frame counter.** A game's frames are not readable from outside it;
// a number that pretended otherwise would be the one thing on this surface
// that lied.

struct OverlayPerformanceWidget: View {
    @Environment(AppModel.self) private var model
    @State private var sampler = SystemLoadSampler()
    @State private var load: SystemLoad?

    static let width: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("PERFORMANCE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Ink.secondary)
            if let load {
                meter("CPU", fraction: load.cpu, detail: percent(load.cpu))
                if let game = load.gameCPU, let name = model.detectedGame?.name {
                    row(name, value: cores(game))
                }
                if let gpu = load.gpu {
                    meter("GPU", fraction: gpu, detail: percent(gpu))
                }
                row("Memory", value: memory(load))
                row("Heat", value: thermal(load.thermal), tint: thermalTint(load.thermal))
            } else {
                Text("Measuring…")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
        }
        .padding(Spacing.snug)
        .frame(width: Self.width, alignment: .leading)
        .background(Palette.canvas.opacity(0.92), in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.relative(dark: 0.10, light: 0.10), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .monospacedDigit()
        .task(id: model.detectedGame?.processIdentifier) {
            let pid = model.detectedGame?.processIdentifier
            let sampler = sampler
            while !Task.isCancelled {
                let reading = await Task.detached(priority: .utility) { sampler.sample(game: pid) }.value
                if let reading { load = reading }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func meter(_ title: String, fraction: Double, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            row(title, value: detail)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.primary.opacity(0.12))
                    Capsule()
                        .fill(tint(for: fraction))
                        .frame(width: max(3, proxy.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 4)
        }
    }

    private func row(_ title: String, value: String, tint: Color? = nil) -> some View {
        HStack(spacing: Spacing.tight) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: Spacing.tight)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? Ink.primary)
                .lineLimit(1)
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// A process's use in cores: "1.4 cores", "38% of a core".
    private func cores(_ share: Double) -> String {
        share >= 1 ? String(format: "%.1f cores", share) : "\(Int((share * 100).rounded()))% of a core"
    }

    private func memory(_ load: SystemLoad) -> String {
        let used = Double(load.memoryUsed) / 1_073_741_824
        let total = Double(load.memoryTotal) / 1_073_741_824
        return String(format: "%.1f of %.0f GB", used, total)
    }

    private func tint(for fraction: Double) -> Color {
        fraction > 0.85 ? Palette.destructive : fraction > 0.6 ? Color(hex: 0xFFB340) : Palette.presenceOnline
    }

    private func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot — slowing"
        case .critical: "Critical"
        @unknown default: "—"
        }
    }

    private func thermalTint(_ state: ProcessInfo.ThermalState) -> Color? {
        switch state {
        case .serious: Color(hex: 0xFFB340)
        case .critical: Palette.destructive
        default: nil
        }
    }
}
