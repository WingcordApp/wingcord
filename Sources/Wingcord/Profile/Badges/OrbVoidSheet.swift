import SwiftUI
import WingcordCore

/// The Void (`2026-10-orb-void`, docs/QUEUE-NOV19.md §2): throw Orbs in, watch
/// the count climb toward the badge's next level. Discord's words throughout;
/// the void itself is this app's own drawing, not Discord's shader (V3).
struct OrbVoidSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @ModalDismiss private var dismiss
    @State private var pulse = 0

    var body: some View {
        VStack(spacing: Spacing.margin) {
            HStack {
                Text("The Void")
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                HeaderCircleButton(systemImage: "xmark", label: "Close", side: 30) { closeAndFlush() }
                    .keyboardShortcut(.cancelAction)
            }

            VoidView(pulse: pulse, reducesMotion: motion.reduceMotion)
                .frame(height: 260)
                .accessibilityHidden(true)

            HStack(spacing: Spacing.group) {
                stat("Orb Balance", model.orbVoidBalance)
                stat("Orbs Voided", model.orbVoidTotal)
            }

            if let line = stateLine {
                Text(line)
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }

            Button {
                if AppSettings.shared.hasAcceptedVoidTerms {
                    throwOne()
                } else {
                    model.orbVoid.isTermsShown = true
                }
            } label: {
                Text("Throw an orb into the void")
                    .font(.system(.headline))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.55, green: 0.25, blue: 0.95))
            .controlSize(.large)
            .disabled(!model.canThrowOrb)

            if let total = model.orbVoidTotal, total > 0 {
                Text("\(total.formatted()) \(total == 1 ? "orb" : "orbs") thrown into the void")
                    .font(.system(.caption))
                    .foregroundStyle(.white.opacity(0.6))
            }

            nextLevel
        }
        .padding(Spacing.group)
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 0.03, green: 0.02, blue: 0.06))
        )
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: Binding(get: { model.orbVoid.isTermsShown }, set: { model.orbVoid.isTermsShown = $0 })) {
            OrbVoidTerms {
                AppSettings.shared.hasAcceptedVoidTerms = true
                model.orbVoid.isTermsShown = false
                throwOne()
            } cancel: {
                model.orbVoid.isTermsShown = false
            }
        }
    }

    private func throwOne() {
        model.sessionController.throwOrb()
        pulse &+= 1
    }

    private func closeAndFlush() {
        model.sessionController.orbVoidFlush?.cancel()
        model.sessionController.flushOrbVoid()
        dismiss()
    }

    private func stat(_ title: String, _ value: Int?) -> some View {
        VStack(spacing: 2) {
            Text(value.map { $0.formatted() } ?? "\u{2013}")
                .font(.system(.title, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(motion.standard, value: value)
            Text(title)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .accessibilityElement(children: .combine)
    }

    /// Discord's lines for a void that can't take a throw.
    private var stateLine: String? {
        if model.orbVoid.loadFailed { return "The void is closed right now. Come back later." }
        guard let status = model.orbVoid.status else { return nil }
        if !status.isEligible || model.orbVoid.isRejected { return "The void is closed right now. Come back later." }
        if (model.orbVoidBalance ?? 0) < 1 { return "The void is still hungry. You are out of orbs." }
        return nil
    }

    /// "Next Badge Tier:" and the bar to it, or Discord's line at the top.
    @ViewBuilder
    private var nextLevel: some View {
        let levels = model.orbVoidLevels
        let total = model.orbVoidTotal ?? 0
        if let next = levels.first(where: { $0.threshold > total }) {
            let floor = levels.last(where: { $0.threshold <= total })?.threshold ?? 0
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Next Badge Tier:")
                        .foregroundStyle(.white.opacity(0.6))
                    if let url = next.tier.simpleIconURL { BadgeArtwork(url: url, side: 18) }
                    Text(next.tier.name ?? next.tier.milestoneText ?? "")
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(total.formatted()) / \(next.threshold.formatted())")
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
                .font(.system(.caption, weight: .semibold))
                ProgressView(value: Double(total - floor), total: Double(max(1, next.threshold - floor)))
                    .tint(Color(red: 0.75, green: 0.45, blue: 1))
                    .accessibilityLabel(Text("Progress to next badge level"))
            }
        } else if !levels.isEmpty {
            Text("Maxed out. Enjoy the view from the bottom.")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// The void itself: a black core that drinks the light at its rim, a ring of
/// colour turning round it, and a flare across it — pulsing once per throw.
private struct VoidView: View {
    var pulse: Int
    var reducesMotion: Bool

    @State private var swallow: CGFloat = 0

    var body: some View {
        SwiftUI.TimelineView(.animation(paused: reducesMotion)) { timeline in
            Canvas { context, size in
                Self.draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate, swallow: swallow)
            }
        }
        .onChange(of: pulse) {
            guard !reducesMotion else { return }
            withAnimation(.spring(duration: 0.18)) { swallow = 1 }
            withAnimation(.spring(duration: 0.6, bounce: 0.3).delay(0.18)) { swallow = 0 }
        }
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval, swallow: CGFloat) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.30 * (1 + swallow * 0.08)
        // The halo.
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius * 1.9, y: center.y - radius * 1.9, width: radius * 3.8, height: radius * 3.8)),
            with: .radialGradient(
                Gradient(colors: [Color(red: 0.55, green: 0.2, blue: 0.9).opacity(0.45), .clear]),
                center: center, startRadius: radius * 0.9, endRadius: radius * 1.9
            )
        )
        // The turning ring of colour.
        var ring = context
        // Turned about the centre: there, round, and back.
        ring.translateBy(x: center.x, y: center.y)
        ring.rotate(by: .radians(time * 0.35))
        ring.translateBy(x: -center.x, y: -center.y)
        ring.addFilter(.blur(radius: 6))
        ring.stroke(
            Path(ellipseIn: CGRect(x: center.x - radius * 1.08, y: center.y - radius * 1.08, width: radius * 2.16, height: radius * 2.16)),
            with: .conicGradient(
                Gradient(colors: [.orange, .pink, .purple, .blue, .cyan, .orange]),
                center: center
            ),
            lineWidth: radius * 0.22
        )
        // The core, with a soft edge.
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
            with: .radialGradient(
                Gradient(stops: [.init(color: .black, location: 0.82), .init(color: .black.opacity(0), location: 1)]),
                center: center, startRadius: 0, endRadius: radius
            )
        )
        // A flare across it.
        var flare = context
        flare.addFilter(.blur(radius: 10))
        flare.fill(
            Path(ellipseIn: CGRect(x: center.x - radius * 2.2, y: center.y - 3, width: radius * 4.4, height: 6)),
            with: .linearGradient(
                Gradient(colors: [.clear, .white.opacity(0.35 + 0.15 * sin(time * 1.3)), .clear]),
                startPoint: CGPoint(x: center.x - radius * 2.2, y: center.y),
                endPoint: CGPoint(x: center.x + radius * 2.2, y: center.y)
            )
        )
    }
}

/// Terms of The Void, in Discord's words — once, before the first throw.
private struct OrbVoidTerms: View {
    var accept: () -> Void
    var cancel: () -> Void

    @State private var agreed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            Text("Terms of The Void")
                .font(.system(.title2, weight: .bold))
            Text("Before you can throw anything into The Void, The Void requires your informed consent.")
                .foregroundStyle(.secondary)
            clause("Destruction is permanent.", "Orbs cast into the Void are destroyed. Not held, not escrowed, not recycled.")
            clause(
                "The Void will not reward you.",
                "The Void confers no rights, rewards, or benefits, and cannot be redeemed for anything, anywhere."
            )
            clause(
                "Orbs have no sensory experience and will not experience pain.",
                "Casting them into The Void does not hurt them. It does, however, make them stop existing."
            )
            Toggle("I have read the above, and I choose oblivion anyway", isOn: $agreed)
                .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Enter The Void", action: accept)
                    .buttonStyle(.borderedProminent)
                    .disabled(!agreed)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.group)
        .frame(width: 440)
    }

    private func clause(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(.headline))
            Text(body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Which void is open — there is only the one.
struct OrbVoidRequest: Identifiable, Hashable {
    var id: Int { 0 }
}

/// Presents `OrbVoidSheet` at the window's root.
struct OrbVoidPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.modal(item: Binding(
            get: { model.orbVoid.isOpen ? OrbVoidRequest() : nil },
            set: { if $0 == nil { model.orbVoid.isOpen = false } }
        )) { _ in
            OrbVoidSheet()
        }
    }
}
