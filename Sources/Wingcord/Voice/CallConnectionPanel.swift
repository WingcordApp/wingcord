import SwiftUI

/// Discord's voice connection panel, from the call card's "Voice Connected":
/// ping, loss each way, jitter, what's being sent, and how it's encrypted.
struct CallConnectionPanel: View {
    var quality: VoiceQuality

    @Environment(AppModel.self) private var model

    var body: some View {
        let numbers = model.callDiagnostics
        VStack(alignment: .leading, spacing: Spacing.snug) {
            HStack(spacing: Spacing.base) {
                Text("Connection")
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: Spacing.base)
                Text(quality.label)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: Spacing.group, verticalSpacing: 6) {
                row("Ping", numbers.pingMilliseconds.map { "\($0) ms" } ?? "\u{2014}")
                row("Incoming packet loss", "\(numbers.inboundLossPercent)%")
                row("Outgoing packet loss", "\(numbers.outboundLossPercent)%")
                row("Jitter", "\(Int(numbers.jitterMilliseconds.rounded())) ms")
                row("Sending", "\(numbers.outgoingKilobits) kbps")
                row("Codec", "Opus, 48 kHz")
                row("Transport encryption", numbers.transportName ?? "\u{2014}")
                row("End-to-end encryption", endToEnd)
            }
            if case .endToEnd(let code) = quality.encryption, !code.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verification code")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Ink.primary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(Spacing.margin)
        .frame(width: 320)
    }

    private var endToEnd: String {
        switch quality.encryption {
        case .endToEnd: "On (DAVE)"
        case .establishing: "Setting up\u{2026}"
        case .transportOnly: "Off"
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
            Text(value)
                .font(.system(.subheadline, weight: .medium).monospacedDigit())
                .foregroundStyle(Ink.primary)
                .gridColumnAlignment(.trailing)
        }
    }
}
