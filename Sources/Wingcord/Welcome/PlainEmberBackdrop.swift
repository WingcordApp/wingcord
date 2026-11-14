import SwiftUI

/// The sign-in ground of a build without MetalForge's effect (`SignInBackdrop`):
/// the ember's colours as a slow mesh under a vignette and, on the welcome, the
/// wordmark and the wings taking turns in the ember's amber, where the particles
/// would gather. Wingcord's own code throughout; nothing of MetalForge's.
///
/// **Calm on purpose**: thirty frames a second, points that drift a few percent,
/// and nothing moving at all under Reduce Motion. A ground, not a show.
struct PlainEmberBackdrop: View {
    var stage: SignInBackdrop.Stage
    var reduceMotion: Bool

    /// When the lockup has formed, so Get Started can follow it.
    static let lockupFormedAt: Double = 2.4
    /// How long the lockup takes to come up, then how long each half holds and
    /// how long the change between them takes.
    private static let appear: Double = 1.6
    private static let wordHold: Double = 3.2
    private static let wingsHold: Double = 2.6
    private static let swap: Double = 1.0

    /// The ember's colours (docs/LOGIN-ONBOARDING.md): the wallpaper's own, and
    /// the lockup's front and glow as Alex darkened them.
    enum Ember {
        static let night = Color(red: 5 / 255, green: 2 / 255, blue: 3 / 255)
        static let maroon = Color(red: 40 / 255, green: 9 / 255, blue: 19 / 255)
        static let red = Color(red: 209 / 255, green: 52 / 255, blue: 31 / 255)
        static let orange = Color(red: 255 / 255, green: 154 / 255, blue: 31 / 255)
        static let amber = Color(red: 242 / 255, green: 182 / 255, blue: 106 / 255)
        static let glow = Color(red: 224 / 255, green: 112 / 255, blue: 26 / 255)
    }

    /// The ground alone and still: under MetalForge's view, for as long as it
    /// hasn't drawn, or for good if Metal can't be had.
    static var still: some View {
        RadialGradient(
            colors: [Color(red: 0.16, green: 0.04, blue: 0.07), Color(red: 0.02, green: 0.008, blue: 0.012)],
            center: .center,
            startRadius: 0,
            endRadius: 900
        )
    }

    @State private var start = Date.now

    var body: some View {
        GeometryReader { proxy in
            SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(start)
                ZStack {
                    mesh(reduceMotion ? 0 : elapsed)
                    vignette
                    if stage == .welcome {
                        lockup(at: elapsed, in: proxy.size)
                            .transition(.opacity)
                    }
                    // The login sits on a dimmer ground, as the ember's does.
                    Ember.night.opacity(stage == .login ? 0.3 : 0)
                }
            }
        }
        .animation(.easeOut(duration: 0.7), value: stage)
        .allowsHitTesting(false)
    }

    /// Night above, the maroon through the middle, the heat low down; the inner
    /// points wander slowly, each on its own clock.
    private func mesh(_ t: Double) -> some View {
        func drift(_ speed: Double, _ amount: Double, _ phase: Double) -> Float {
            Float(sin(t * speed + phase) * amount)
        }
        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.55 + drift(0.11, 0.04, 0)],
                [0.5 + drift(0.07, 0.07, 1), 0.6 + drift(0.09, 0.05, 2)],
                [1, 0.5 + drift(0.13, 0.04, 3)],
                [0, 1], [0.5 + drift(0.05, 0.1, 4), 1], [1, 1],
            ],
            colors: [
                Ember.night, Ember.night, Ember.night,
                Ember.maroon, Ember.maroon.mix(with: Ember.red, by: 0.22), Ember.maroon,
                Ember.red.mix(with: Ember.night, by: 0.45),
                Ember.orange.mix(with: Ember.red, by: 0.55).mix(with: Ember.night, by: 0.2),
                Ember.red.mix(with: Ember.night, by: 0.5),
            ]
        )
    }

    private var vignette: some View {
        RadialGradient(
            colors: [.clear, Ember.night.opacity(0.85)],
            center: .center,
            startRadius: 140,
            endRadius: 1100
        )
    }

    /// The word, then the wings, then the word: where the particles' lockup
    /// sits, lifted above Get Started, coming up blurred as they gather.
    private func lockup(at t: Double, in size: CGSize) -> some View {
        let shown = reduceMotion ? 1 : min(1, max(0, (t - (Self.lockupFormedAt - Self.appear)) / Self.appear))
        let wings = reduceMotion ? 0 : wingsAmount(t - Self.lockupFormedAt)
        let height = size.height
        let fill = LinearGradient(colors: [Ember.amber, Ember.glow], startPoint: .top, endPoint: .bottom)
        return ZStack {
            Text(verbatim: "Wingcord")
                .font(.system(size: height * 0.13, weight: .bold))
                .foregroundStyle(fill)
                .opacity(1 - wings)
                .scaleEffect(1 - wings * 0.04)
            WingsShape()
                .fill(fill)
                .frame(width: height * 0.26, height: height * 0.26)
                .opacity(wings)
                .scaleEffect(0.96 + wings * 0.04)
        }
        .shadow(color: Ember.glow.opacity(0.55), radius: height * 0.02)
        .blur(radius: (1 - shown) * 10)
        .opacity(shown)
        .position(x: size.width / 2, y: height * 0.42)
    }

    /// 0 on the word, 1 on the wings, eased between them, round and round.
    private func wingsAmount(_ since: Double) -> Double {
        guard since > 0 else { return 0 }
        let cycle = Self.wordHold + Self.swap + Self.wingsHold + Self.swap
        let p = since.truncatingRemainder(dividingBy: cycle)
        func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        if p < Self.wordHold { return 0 }
        if p < Self.wordHold + Self.swap { return ease((p - Self.wordHold) / Self.swap) }
        if p < Self.wordHold + Self.swap + Self.wingsHold { return 1 }
        return 1 - ease((p - Self.wordHold - Self.swap - Self.wingsHold) / Self.swap)
    }
}
