import SwiftUI
import WingcordCore

/// The onboarding gate, as the detail column.
///
/// **A destination, not a modal**, which is why it is a `WorkspacePresentation`
/// case rather than a sheet. Two things follow from that and both are the point:
/// the rail stays live, so somebody can step away to another server and come
/// back to a gate exactly where they left it; and the column keeps one view
/// type, which is `INVARIANTS.md` §1 — a structural detail swap makes macOS
/// re-resolve the split view's widths and steal from the sidebar until the rail
/// slides underneath.
///
/// **The card is content and only the bar is glass** (docs/BETA3.md D2, the
/// HIG's own split: Liquid Glass is the layer of controls floating over
/// content, never the content). The card used to be clear glass over the
/// server's artwork, which read as a sheet of glass with words on it (Alex,
/// 2026-11-18: "all glass … goes against HIG"); it is the raised solid
/// surface now, with a hairline and a shadow to lift it off the picture. The
/// action bar keeps the glass, because its buttons float over moving content.
/// No welcome step: the card's head carries the server's face, name and how
/// far through its questions the reader is.
struct ServerJoinGatePane: View, Equatable {
    var presentation: ServerJoinGatePresentation

    static func == (lhs: ServerJoinGatePane, rhs: ServerJoinGatePane) -> Bool {
        lhs.presentation == rhs.presentation
    }

    var toggleOption: (UInt64, UInt64) -> Void = { _, _ in }
    var back: () -> Void = {}
    var forward: () -> Void = {}
    var dismiss: () -> Void = {}

    @Environment(\.motion) private var motion

    var body: some View {
        ScrollView {
            card
                .surfaceColumn(Proportions.surfaceColumnMax)
                .padding(.vertical, Spacing.section)
                // Centred in the window rather than parked at the top: the card
                // is the only thing on this surface, and a page with one object
                // pinned to its ceiling reads as content that failed to load
                // underneath.
                .frame(minHeight: minimumStageHeight, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
        .softScrollEdgesVertical()
        // **The server's artwork IS the surface**, edge to edge and under the
        // window's own chrome — which is why the gate hides the channel list and
        // the toolbar rather than sitting inside them. It is the one screen in
        // the app that is about a server rather than about something in it, so
        // the server gets the whole of it.
        .background { cover }
        // A floating bar, not a hand-drawn band: `safeAreaBar` registers it, so
        // the reservation and the bar cannot disagree and the content passing
        // under it gets the system's progressive blur.
        .floatingBottomBar {
            ServerJoinGateBar(
                presentation: presentation,
                back: back,
                forward: forward
            )
            .surfaceColumn(Proportions.surfaceColumnMax)
            .padding(.top, Spacing.base)
        }
        // One measurement, guarded and unanimated: a `@State` write of an equal
        // value still invalidates, and this fires on every frame of a resize.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            guard abs(stageHeight - height) > 0.5 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { stageHeight = height }
        }
        .animation(motion.standard, value: presentation.body)
        .animation(motion.standard, value: presentation.failure)
    }

    /// How tall the card's stage is at minimum, so it centres rather than
    /// floating at the top of a short window. Read from the scroll view's own
    /// proposal, which is the detail column's height.
    @State private var stageHeight: CGFloat = 0

    private var minimumStageHeight: CGFloat {
        // Zero until measured — a `minHeight` of zero is no constraint at all,
        // which is exactly the right behaviour for the first frame.
        max(stageHeight - Spacing.section * 2, 0)
    }

    // MARK: The picture

    /// The server's artwork, filling the surface.
    ///
    /// **`.fill` with a clip, not `.fit`.** A banner is 16:5 and this box is
    /// roughly 3:2, so fitting it letterboxes the server's own picture between
    /// two bands of ground — which is the thing a full-bleed background exists
    /// to avoid. Filling crops the sides, which is what every hero image in this
    /// app does.
    ///
    /// A server with neither banner nor splash draws the raised surface: a flat
    /// step above the page rather than a grey box with a broken-image feel.
    private var cover: some View {
        Rectangle()
            .fill(Palette.surfaceRaised)
            .overlay {
                if let coverURL = presentation.coverURL {
                    RemoteImage(url: coverURL, side: 1600, bucket: .artwork) { Color.clear }
                        .aspectRatio(contentMode: .fill)
                }
            }
            // **A scrim, and it is not optional.** The card is a translucent
            // material, so whatever is behind it comes through — and a server
            // banner is arbitrary artwork that can be white, busy, or both. Two
            // stops rather than one flat wash: darkest at the foot where the
            // action bar's labels sit over it, lighter at the head where the
            // picture is still worth seeing.
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Palette.canvas.opacity(0.35), location: 0),
                        .init(color: Palette.canvas.opacity(0.62), location: 0.55),
                        .init(color: Palette.canvas.opacity(0.80), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
            // Under the titlebar and the window's foot, which is what makes this
            // a takeover rather than a page with a picture on it.
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    // MARK: The card

    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            GateHeader(presentation: presentation)
            switch presentation.body {
            case .question(let question):
                QuestionStep(question: question, toggleOption: toggleOption)
            case .rules(let rules):
                RulesStep(rules: rules, serverName: presentation.serverName, guildID: presentation.guildID)
            }

            if let failure = presentation.failure {
                GateFailureRow(message: failure)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.group)
        // **Solid, because it is what is read.** Questions and their answers are
        // content; glass under them made every word depend on the server's
        // picture. The raised surface is the theme's own, opaque.
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.edge, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        .overlay(alignment: .topTrailing) { closeButton }
    }

    /// The way out.
    ///
    /// **The gate is skippable and saying so is the honest thing.** Discord's
    /// own flow has no close button and traps somebody who opened a server to
    /// read one message; the server stays gated either way — the rules row on
    /// the Server Guide and the pending banner both still say so — so this costs
    /// nothing but the nag.
    private var closeButton: some View {
        Button(action: dismiss) {
            Image(systemName: "xmark")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
                .frame(width: Metrics.control, height: Metrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .padding(Spacing.snug)
        .accessibilityLabel("Skip for now")
    }
}

// MARK: - Whose questions

/// The server's face and name over every step, and how far through them the
/// reader is — the welcome step's one job, kept without the step.
private struct GateHeader: View {
    var presentation: ServerJoinGatePresentation

    private static let iconSide: CGFloat = 40

    var body: some View {
        HStack(spacing: Spacing.snug) {
            RemoteImage(url: presentation.iconURL, side: Self.iconSide) {
                Text(presentation.monogram)
                    .font(.system(size: Self.iconSide * 0.36, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: Self.iconSide, height: Self.iconSide)
                    .background(Palette.canvas)
            }
            .frame(width: Self.iconSide, height: Self.iconSide)
            .clipShape(.rect(cornerRadius: Self.iconSide * 0.3, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.serverName)
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if presentation.stepCount > 1 {
                    Text("Step \(presentation.stepNumber) of \(presentation.stepCount)")
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: Metrics.control)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - A question

private struct QuestionStep: View {
    var question: ServerJoinGatePresentation.Question
    var toggleOption: (UInt64, UInt64) -> Void

    /// Two up, like Discord's. The minimum is what drops it to one column in a
    /// narrow window rather than squeezing two unreadable ones.
    private static let columnMinimum: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            Text(question.title)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.columnMinimum), spacing: Spacing.snug)],
                alignment: .leading,
                spacing: Spacing.snug
            ) {
                ForEach(question.options) { option in
                    GateOptionChip(option: option) { toggleOption($0, question.promptID) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One answer.
///
/// **Deliberately not `OptionChip`.** The Channels & Roles chip writes on the
/// click and says what it unlocks; this one collects an answer and says how many
/// people already made the same choice. Sharing them would mean a chip that
/// takes a save closure it does not use on one page and a member count it does
/// not draw on the other.
private struct GateOptionChip: View {
    var option: ServerJoinGatePresentation.Question.Option
    var toggle: (UInt64) -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button {
            toggle(option.id)
        } label: {
            HStack(alignment: .top, spacing: Spacing.snug) {
                SurfaceGlyphView(glyph: option.glyph, isEmphasised: option.isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let count = option.memberCount {
                        Text("\(count, format: .number) people in common")
                            .font(.system(.caption))
                            .foregroundStyle(Palette.accent)
                            .lineLimit(1)
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: Spacing.tight)

                Image(symbol: option.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(
                        option.isSelected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.quaternary)
                    )
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.top, 2)
            }
            .padding(Spacing.snug)
            // Fills the grid row's height: `LazyVGrid` sizes a row to its
            // tallest child and top-aligns the rest, so an option with a count
            // beside one without leaves a ragged foot.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                    .strokeBorder(
                        option.isSelected
                            ? AnyShapeStyle(Palette.accent.opacity(0.55))
                            : AnyShapeStyle(Ink.quaternary),
                        lineWidth: 1
                    )
            }
            .contentShape(.rect(cornerRadius: Radius.glass))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.standard, value: option.isSelected)
        .animation(motion.fadeQuick, value: isHovering)
        .accessibilityLabel(Text(option.title))
        .accessibilityValue(Text(option.isSelected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(option.isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Relative fills throughout, for the reason on the rules list: the card
    /// behind these is glass, and an opaque chip inside it stops the material
    /// lensing under exactly the thing the reader is looking at.
    private var fill: Color {
        if option.isSelected { return Palette.accent.opacity(0.22) }
        return isHovering ? Palette.selectionFill : Palette.hoverFill
    }
}

// MARK: - The rules

private struct RulesStep: View {
    var rules: ServerJoinGatePresentation.Rules
    var serverName: String
    var guildID: GuildID

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("One last step")
                    .font(.system(.callout))
                    .foregroundStyle(Ink.tertiary)
                Text("Read and agree to the server rules")
                    .font(.system(.title2, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = rules.detail {
                    RulesDetail(markdown: detail, guildID: guildID)
                        .padding(.top, Spacing.tight)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rules.rules.enumerated()), id: \.offset) { index, rule in
                    if index > 0 { SurfaceDivider(leading: Spacing.margin + 22 + Spacing.snug) }
                    GateRuleRow(number: index + 1, text: rule, guildID: guildID)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // **A white wash, not `Palette.surface`.** The card around this is
            // glass now, and an opaque fill inside it is §4 rule 3 from the
            // inside: the region stops lensing and reads as a plate laid on the
            // material. A relative lift keeps the banner coming through, and it
            // is the same value every grouped region in this app uses.
            .background(
                Palette.hoverFill,
                in: .rect(cornerRadius: Radius.card, style: .continuous)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The server's own paragraph above its rules, drawn as Discord markdown.
private struct RulesDetail: View {
    var markdown: String
    var guildID: GuildID

    @Environment(AppModel.self) private var model

    var body: some View {
        ProseText(
            markdown: markdown,
            font: .system(.callout),
            color: InkColor.secondary,
            mentions: model.joinMentionContext(for: guildID),
            onLink: { model.openLink($0) }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GateRuleRow: View {
    var number: Int
    /// Discord markdown, as the server wrote it.
    var text: String
    var guildID: GuildID

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            Text("\(number)")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(Ink.tertiary)
                .monospacedDigit()
                .frame(width: 22, alignment: .trailing)
                .padding(.top, 3)
            // The rule as a message draws it: channels, roles, people, emoji,
            // links and timestamps, not their raw `<#…>` codes.
            ProseText(
                markdown: text,
                font: .system(.callout),
                color: InkColor.secondary,
                mentions: model.joinMentionContext(for: guildID),
                onLink: { model.openLink($0) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.vertical, Spacing.snug)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - A refusal

/// Why the submit did not land.
///
/// On the card rather than in the bar: it can be two lines — Discord's own
/// *"This user is already a member, join request is already closed"* is one of
/// them — and a bar that grows to fit a sentence moves the button somebody is
/// aiming at.
private struct GateFailureRow: View {
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(.caption))
                .foregroundStyle(Palette.destructive)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.snug)
        .background(
            Palette.destructive.opacity(0.12),
            in: .rect(cornerRadius: Radius.chip, style: .continuous)
        )
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The bar

/// The gate's one piece of floating chrome.
///
/// **One glass body per control, merged in a container**, exactly as the
/// Channels & Roles bar is: two capsules that reflow as one when Back appears on
/// the second step. The guidance sentence is an ordinary sibling *outside* the
/// container — §4 rule 4, a container promotes its glass elements above ordinary
/// siblings, and text placed inside one is text a capsule can be drawn over.
private struct ServerJoinGateBar: View {
    var presentation: ServerJoinGatePresentation
    var back: () -> Void
    var forward: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: Spacing.snug) {
            GlassEffectContainer(spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    if presentation.canGoBack {
                        GateBarButton(
                            title: "Back",
                            systemImage: "arrow.left",
                            placesImageFirst: true,
                            action: back
                        )
                        .transition(.materialize)
                    }
                }
            }

            progress

            Spacer(minLength: Spacing.base)

            if let guidance {
                Text(guidance)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            if presentation.isSubmitting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Finishing up")
            }

            GlassEffectContainer(spacing: Spacing.base) {
                GateBarButton(
                    title: presentation.forward.title,
                    systemImage: presentation.forward.symbolName,
                    placesImageFirst: false,
                    isEmphasised: true,
                    action: forward
                )
                .disabled(!presentation.forward.isEnabled || presentation.isSubmitting)
                .opacity(presentation.forward.isEnabled ? 1 : 0.45)
            }
        }
        .animation(motion.glassMorph, value: presentation.canGoBack)
        .animation(motion.standard, value: presentation.forward)
        .animation(motion.standard, value: presentation.isSubmitting)
    }

    /// How far along, as a row of bars.
    ///
    /// **Bars rather than "Step 2 of 3"**, because the count is already on the
    /// question itself and a second reading of the same number is noise. A
    /// single-step gate draws nothing: one full bar says nothing a person did
    /// not already know.
    @ViewBuilder
    private var progress: some View {
        if presentation.stepCount > 1 {
            HStack(spacing: Spacing.tight) {
                ForEach(0..<presentation.stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index < presentation.stepNumber ? Palette.accent : Palette.selectionFill)
                        .frame(width: 18, height: 4)
                }
            }
            .animation(motion.standard, value: presentation.stepNumber)
            .accessibilityElement()
            .accessibilityLabel(
                "Step \(presentation.stepNumber) of \(presentation.stepCount)"
            )
        }
    }

    /// The sentence beside the forward control.
    ///
    /// Different on every kind of step, and each one is the thing somebody needs
    /// at that moment: what kind of answer a question takes, what the answer they
    /// gave will get them, and what pressing Finish actually means.
    private var guidance: String? {
        switch presentation.body {
        case .question(let question):
            // A required question with nothing chosen is the one moment the
            // forward control refuses, so this is where the reason goes.
            if question.isRequired, !question.options.contains(where: \.isSelected) {
                "Choose at least one to continue."
            } else {
                question.grants ?? question.guidance
            }
        case .rules:
            "Pressing Finish records that you have read and agreed."
        }
    }
}

/// A control in the bar.
///
/// Its own type rather than `SurfaceFilledButton`, because that one is a
/// *region inside a card's material* — the right answer on an opaque page and
/// the wrong one here, where the bar floats and its controls are the glass.
private struct GateBarButton: View {
    var title: String
    var systemImage: String?
    var placesImageFirst: Bool
    var isEmphasised = false
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.tight) {
                if placesImageFirst, let systemImage { glyph(systemImage) }
                Text(title)
                    .font(.system(.callout, weight: .semibold))
                if !placesImageFirst, let systemImage { glyph(systemImage) }
            }
            .foregroundStyle(isEmphasised ? AnyShapeStyle(.white) : AnyShapeStyle(Ink.primary))
            .padding(.horizontal, Spacing.margin)
            .frame(minWidth: 104, minHeight: Metrics.control + Spacing.base)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // Layout first, glass last — §4 rule 1.
        .modifier(GateBarMaterial(isEmphasised: isEmphasised, isEnabled: isEnabled))
    }

    private func glyph(_ name: String) -> some View {
        Image(symbol: name)
            .font(.system(.caption, weight: .semibold))
    }
}

/// The bar control's material, which is two different materials.
///
/// A `ViewModifier` rather than a branch in the body, so the button keeps one
/// view identity across a step where the forward control changes emphasis —
/// branching would give it two, and the capsule would pop rather than morph.
private struct GateBarMaterial: ViewModifier {
    var isEmphasised: Bool
    var isEnabled: Bool

    func body(content: Content) -> some View {
        if isEmphasised, isEnabled {
            content.emphasisChrome(Palette.accent)
        } else {
            content.interactiveChrome()
        }
    }
}
