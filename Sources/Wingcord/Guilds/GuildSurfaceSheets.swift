import SwiftUI
import WingcordCore

// MARK: - The two sheets these pages raise
//
// Both are presented ONCE, at the window root, from a value on the store — the
// same rule every other raised surface in this app follows. A `.sheet` written
// inside a page is evaluated as part of that page's body, including its title
// strings, on every evaluation of the page.

struct GuildSurfacePresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        // **Both sheets' contents are read HERE, in the modifier's own body**,
        // rather than inside the presentation closures. The connect steps arrive
        // on a second route while the sheet is already up, and a read that
        // happens only inside a closure SwiftUI calls to build the presented
        // view is not a dependency this view is guaranteed to be invalidated by.
        // Read at the top, the arrival re-runs this body and the sheet gains its
        // steps — which is the whole reason the sheet opens before they land.
        let steps = model.gameServerInstructions
        let rules = model.serverRulesPresentation
        return content
            .modal(item: $model.gameServerConnect) { request in
                GameServerConnectSheet(
                    server: request.server,
                    steps: steps,
                    dismiss: { model.gameServerConnect = nil }
                )
            }
            .modal(isPresented: rulesBinding) {
                if let rules {
                    ServerRulesSheet(
                        presentation: rules,
                        agree: { model.agreeToServerRules() },
                        dismiss: {
                            model.serverRulesGuildID = nil
                            model.serverRulesSubmission = nil
                        }
                    )
                }
            }
    }

    /// **The setter may only clear the store when the store is still showing
    /// this presentation**, which is the rule the profile presenter's bindings
    /// already record. Here it is simpler — there is one depth — but the shape
    /// is kept so a second surface added later cannot dismiss the first on its
    /// way in.
    private var rulesBinding: Binding<Bool> {
        Binding(
            get: { model.serverRulesGuildID != nil },
            set: { if !$0 { model.serverRulesGuildID = nil } }
        )
    }
}

extension View {
    /// Applied once, at the window root, above `.environment(model)`.
    func presentsGuildSurfaces() -> some View {
        modifier(GuildSurfacePresenter())
    }
}

// MARK: - Connecting to a game server

/// What the game needs, and the address to paste into it.
///
/// **The address is the part that always works.** The steps come from a second
/// route and may not arrive at all; the sheet is built so that is a missing
/// paragraph rather than a broken sheet, because somebody who opened this wanted
/// the address.
struct GameServerConnectSheet: View {
    var server: GameServer
    var steps: [String]
    var dismiss: () -> Void

    private static let width: CGFloat = 430

    @Environment(\.motion) private var motion
    /// The steps, with their `**bold**` runs resolved.
    ///
    /// Parsed **once per arrival** in a task rather than in the body: an
    /// `AttributedString(markdown:)` in a view body is a full markdown parse per
    /// render, and this sheet re-renders on every hover of its copy button.
    @State private var parsed: [AttributedString] = []
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !parsed.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    ForEach(Array(parsed.enumerated()), id: \.offset) { index, step in
                        StepRow(number: index + 1, text: step)
                    }
                }
                .padding(.horizontal, Spacing.group)
                .padding(.bottom, Spacing.margin)
                .transition(.opacity)
            }
            if let address = server.address {
                addressBlock(address)
            }
            footer
        }
        .frame(width: Self.width)
        .animation(motion.panel, value: parsed)
        .task(id: steps) {
            parsed = steps.map(Self.attributed)
        }
    }

    private var header: some View {
        ModalHeader(
            title: server.name,
            subtitle: Text(parsed.isEmpty
                ? "Add this address in your game to join."
                : "Follow these steps in your game to join."),
            close: dismiss
        )
    }

    private func addressBlock(_ address: String) -> some View {
        HStack(spacing: Spacing.snug) {
            Text(address)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Ink.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.snug)
                .frame(height: Metrics.control + Spacing.base)
                .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.row, style: .continuous))
            CopyButton(value: address, didCopy: $didCopy)
        }
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    private var footer: some View {
        HStack(spacing: Spacing.base) {
            Spacer(minLength: 0)
            ModalButton(title: "Done", symbolName: "checkmark", role: .act, action: dismiss)
        }
        .padding(Spacing.margin)
    }

    /// `**Favorites**` to a bold run.
    ///
    /// `nonisolated static` so it is a pure function over a string: it is called
    /// from a task, it touches nothing, and a failure falls back to the plain
    /// sentence — an instruction with visible asterisks in it is still an
    /// instruction, where a dropped one is a step nobody can follow.
    nonisolated private static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

/// One numbered instruction.
private struct StepRow: View {
    var number: Int
    var text: AttributedString

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            Text("\(number)")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
                .frame(width: 22, height: 22)
                .background(Palette.hoverFill, in: .circle)
            Text(text)
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Server rules

/// The rules a server makes people agree to.
///
/// **The Agree button exists only where it can work.** Somebody who is already
/// a full member of the server agreed when they joined, and a second agreement
/// is a control with nothing behind it — so for them this is what it says it is:
/// the rules, to read. For somebody still *pending* it is the gate, and the
/// button is real: `PUT /guilds/{id}/requests/@me`, with the whole form and its
/// version echoed back.
struct ServerRulesSheet: View {
    var presentation: ServerRulesPresentation
    var agree: () -> Void
    var dismiss: () -> Void

    private static let width: CGFloat = 460
    private static let maxListHeight: CGFloat = 380

    @Environment(\.motion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(
                title: "Server Rules",
                subtitle: Text(presentation.detail ?? "What \(presentation.serverName) asks of everyone here."),
                close: dismiss
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(presentation.rules.enumerated()), id: \.offset) { index, rule in
                        if index > 0 { SurfaceDivider(leading: Spacing.margin + 22 + Spacing.snug) }
                        RuleRow(number: index + 1, text: rule)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.groupedFill, in: .rect(cornerRadius: Radius.card))
            }
            // A cap rather than a fixed height: a server with three rules gets a
            // short sheet, and one with fifteen scrolls instead of running off
            // the screen.
            .frame(maxHeight: Self.maxListHeight)
            .scrollBounceBehavior(.basedOnSize)
            .padding(.horizontal, Spacing.group)

            footer
        }
        .frame(width: Self.width)
        .animation(motion.standard, value: presentation.outcomeMessage)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if let message = presentation.outcomeMessage {
                Text(message)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            HStack(spacing: Spacing.base) {
                if presentation.canAgree || presentation.isWorking {
                    // The sentence that makes the button mean something. Beside
                    // it rather than under it, because a press is an agreement
                    // and the words have to be where the pointer already is.
                    Text("Pressing this records that you have read and agreed.")
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.base)
                if presentation.canAgree || presentation.isWorking {
                    ModalButton(
                        title: "Agree",
                        symbolName: "checkmark.seal.fill",
                        role: .act,
                        isWorking: presentation.isWorking,
                        action: agree
                    )
                } else {
                    ModalButton(title: "Done", symbolName: "checkmark", role: .act, action: dismiss)
                }
            }
        }
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.margin)
        .padding(.bottom, Spacing.margin)
    }
}

private struct RuleRow: View {
    var number: Int
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            Text("\(number)")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(Ink.tertiary)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)
                .padding(.top, 2)
            Text(text)
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.snug)
        .accessibilityElement(children: .combine)
    }
}
