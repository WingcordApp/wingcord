import SwiftUI

/// A question, as a card (D11b's Alert): a hero, a title, what it does in a
/// few lines, perhaps another way out, and its capsules.
///
/// **Two capsules share the row equally**, the way out leading and the act
/// trailing; three stack, the act first. Every action closes the card after it
/// has run, so a site writes what happens and not the dismissal.
struct ModalAlert<Accessory: View>: View {
    var hero: ModalHero?
    var title: String
    var message: Text?
    var points: [ModalPoint]
    var link: ModalLink?
    var actions: [ModalAlertAction]
    /// Discord's "Don't ask again", where a dialog offers it.
    var suppression: Binding<Bool>?
    @ViewBuilder var accessory: Accessory

    @ModalDismiss private var dismiss

    init(
        hero: ModalHero? = nil,
        title: String,
        message: Text? = nil,
        points: [ModalPoint] = [],
        link: ModalLink? = nil,
        actions: [ModalAlertAction],
        suppression: Binding<Bool>? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.hero = hero
        self.title = title
        self.message = message
        self.points = points
        self.link = link
        self.actions = actions
        self.suppression = suppression
        self.accessory = accessory()
    }

    static var width: CGFloat { 400 }

    var body: some View {
        VStack(spacing: Spacing.margin) {
            if let hero {
                hero.padding(.bottom, Spacing.tight)
            }
            Text(verbatim: title)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(Ink.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            if let message {
                message
                    .font(.system(.body))
                    .foregroundStyle(Ink.secondary)
                    .tint(Palette.accent)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !points.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    ForEach(points) { point in point }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            accessory

            if let suppression {
                Toggle("Don't ask again", isOn: suppression)
                    .toggleStyle(.checkbox)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
            }

            if let link {
                Button(link.title, action: link.perform)
                    .buttonStyle(.plain)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }

            buttons
                .padding(.top, Spacing.tight)
        }
        .padding(.horizontal, Spacing.group)
        .padding(.top, hero == nil ? Spacing.group + Spacing.tight : Spacing.group)
        .padding(.bottom, Spacing.margin)
        .frame(width: Self.width)
    }

    @ViewBuilder
    private var buttons: some View {
        GlassEffectContainer(spacing: Spacing.snug) {
            if actions.count <= 2 {
                HStack(spacing: Spacing.snug) {
                    ForEach(actions) { action in button(action) }
                }
            } else {
                VStack(spacing: Spacing.base) {
                    ForEach(actions.reversed()) { action in button(action) }
                }
            }
        }
    }

    private func button(_ action: ModalAlertAction) -> some View {
        ModalButton(
            title: action.title,
            symbolName: action.symbolName,
            role: action.role,
            isIrreversible: action.isIrreversible,
            fills: true
        ) {
            action.perform()
            if action.closes { dismiss() }
        }
        .disabled(!action.isEnabled)
    }
}

/// One of an alert's capsules.
struct ModalAlertAction: Identifiable {
    var title: String
    var symbolName: String?
    var role: ModalButton.Role
    var isIrreversible = false
    /// Closes the card once it has run — false for an act that reports its
    /// own outcome and closes the card itself.
    var closes = true
    /// Whether it can be pressed yet — Save with nothing changed cannot.
    var isEnabled = true
    var perform: () -> Void

    var id: String { title }

    /// The way out, in Discord's words where they are not "Cancel".
    static func cancel(_ title: String = "Cancel", perform: @escaping () -> Void = {}) -> ModalAlertAction {
        ModalAlertAction(title: title, symbolName: "xmark", role: .cancel, perform: perform)
    }

    /// The act — the accent's glass.
    static func act(
        _ title: String, symbol: String? = nil, irreversible: Bool = false, enabled: Bool = true,
        perform: @escaping () -> Void
    ) -> ModalAlertAction {
        ModalAlertAction(
            title: title, symbolName: symbol, role: .act, isIrreversible: irreversible,
            isEnabled: enabled, perform: perform
        )
    }

    /// A destructive result nobody chose — Discard, Exit without saving: red glass.
    static func destructive(_ title: String, symbol: String? = nil, perform: @escaping () -> Void) -> ModalAlertAction {
        ModalAlertAction(title: title, symbolName: symbol, role: .destructive, isIrreversible: true, perform: perform)
    }

    /// Another way forward that is not the act.
    static func secondary(_ title: String, symbol: String? = nil, perform: @escaping () -> Void) -> ModalAlertAction {
        ModalAlertAction(title: title, symbolName: symbol, role: .secondary, perform: perform)
    }

    /// The one button of a notice — "Okay", Escape and Return both.
    static func okay(_ title: String = "Okay", perform: @escaping () -> Void = {}) -> ModalAlertAction {
        ModalAlertAction(title: title, symbolName: "checkmark", role: .act, perform: perform)
    }
}

/// What a card leads with: a symbol in a disc of its tint, or a face — a
/// person's round, a server's rounded square — with a badge saying what is
/// about to happen to it.
struct ModalHero: View {
    enum Picture {
        case symbol(String, tint: Color)
        case avatar(URL?, monogram: String)
        case serverIcon(URL?, monogram: String)
    }

    var picture: Picture
    /// A symbol worn at the face's foot — the eye struck through on Ignore.
    var badge: String?

    @Environment(\.motion) private var motion
    @Environment(\.modalMorphProgress) private var morph

    static let side: CGFloat = 76

    /// A symbol in a disc of its tint — quiet ink unless the question is a warning.
    static func symbol(_ name: String, tint: Color = Ink.primary) -> ModalHero {
        ModalHero(picture: .symbol(name, tint: tint))
    }

    /// A person, with what is about to happen to them worn at the foot.
    static func avatar(_ url: URL?, monogram: String, badge: String? = nil) -> ModalHero {
        ModalHero(picture: .avatar(url, monogram: monogram), badge: badge)
    }

    /// A server, likewise.
    static func serverIcon(_ url: URL?, monogram: String, badge: String? = nil) -> ModalHero {
        ModalHero(picture: .serverIcon(url, monogram: monogram), badge: badge)
    }

    var body: some View {
        face
            .frame(width: Self.side, height: Self.side)
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Ink.primary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30, height: 30)
                        .background(Palette.surfaceRaised, in: .circle)
                        .overlay { Circle().strokeBorder(Palette.surface, lineWidth: 3) }
                        .offset(x: 6, y: 4)
                        // It bounces once as the card lands.
                        .keyframeAnimator(initialValue: CGFloat(1), trigger: morph >= 1) { content, scale in
                            content.scaleEffect(scale)
                        } keyframes: { _ in
                            if motion.reduceMotion {
                                LinearKeyframe(1, duration: 0.01)
                            } else {
                                SpringKeyframe(1.22, duration: 0.14, spring: .snappy)
                                SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                            }
                        }
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var face: some View {
        switch picture {
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Self.side, height: Self.side)
                .background(tint.opacity(tint == Ink.primary ? 0.08 : 0.16), in: .circle)
        case .avatar(let url, let monogram):
            RemoteImage(url: url, side: Self.side) {
                monogramTile(monogram)
            }
            .clipShape(.circle)
        case .serverIcon(let url, let monogram):
            RemoteImage(url: url, side: Self.side) {
                monogramTile(monogram)
            }
            .clipShape(.rect(cornerRadius: Self.side * 0.28, style: .continuous))
        }
    }

    private func monogramTile(_ monogram: String) -> some View {
        Text(monogram)
            .font(.system(size: Self.side * 0.34, weight: .semibold))
            .foregroundStyle(Ink.primary)
            .frame(width: Self.side, height: Self.side)
            .background(Palette.hoverFill)
    }
}

/// One line of what an act does: a check in the accent's disc, or a note
/// behind an ⓘ in the quieter ink.
struct ModalPoint: View, Identifiable {
    var text: String
    var isNote = false
    /// A symbol of its own in place of the check — a feature rather than a
    /// consequence.
    var symbolName: String?
    /// A quieter line under it — Discord's "You can unhide them at any time".
    var detail: String?

    var id: String { text }

    static func check(_ text: String, detail: String? = nil) -> ModalPoint {
        ModalPoint(text: text, detail: detail)
    }
    static func note(_ text: String, detail: String? = nil) -> ModalPoint {
        ModalPoint(text: text, isNote: true, detail: detail)
    }
    static func feature(_ text: String, symbol: String) -> ModalPoint { ModalPoint(text: text, symbolName: symbol) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.base + Spacing.hair) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 22)
            } else {
                Image(systemName: isNote ? "info.circle.fill" : "checkmark.circle.fill")
                    .font(.system(.body, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        isNote ? AnyShapeStyle(Palette.surface) : AnyShapeStyle(Color.white),
                        isNote ? AnyShapeStyle(Ink.secondary) : AnyShapeStyle(Palette.accent)
                    )
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: text)
                    .font(.system(.body, weight: isNote ? .regular : .medium))
                    .foregroundStyle(isNote ? Ink.secondary : Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(verbatim: detail)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Another way out of a question, under it — "Block Instead".
struct ModalLink {
    var title: String
    var perform: () -> Void
}
