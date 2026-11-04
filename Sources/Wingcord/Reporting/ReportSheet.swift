import SwiftUI
import WingcordCore
import WingcordNet

/// Discord's report flow, walked.
///
/// **Every question on screen comes off the wire.** The tree is fetched once per
/// subject kind and the sheet is a renderer for it — headers, choices,
/// checkboxes, the summary and the acknowledgement are all node shapes, not
/// screens written here. A client that hard-coded the categories would ship a
/// report form that goes stale the week Discord adds one, and the categories are
/// the entire content of the flow.
///
/// The walk itself is `ReportPath`, a value with no view in it, so a submission
/// whose breadcrumbs describe a path the reader did not take is a bug a test can
/// catch.
struct ReportSheet: View {
    var request: ReportRequest

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @Environment(\.openURL) private var openURL

    /// Where the walk has got to. `@State` and not on the store: it belongs to
    /// this presentation and dies with it, and a half-walked path left on the
    /// store is a report that resumes itself the next time anybody opens one.
    @State private var path: ReportPath?
    /// The node an auto-submitting screen has already posted, so re-rendering
    /// the same screen does not file a second report.
    @State private var autoSubmitted: Int?
    /// Whether the last step went deeper — the way the next page slides.
    @State private var isGoingForward = true

    private static let width: CGFloat = 460
    private static let maximumHeight: CGFloat = 520

    private var menu: ReportMenu? { model.reportMenus[request.subject.kind] }
    private var node: ReportNode? {
        guard let menu, let path else { return nil }
        return menu[path.currentNodeID]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(
                title: node?.header ?? "Report",
                subtitle: node?.subheader.map { Text(verbatim: $0) },
                close: { model.dismissReport() }
            )
            // **Each step turns in place** — the card resizes to the next
            // question and the page slides in from the way it was reached.
            ZStack(alignment: .top) {
                if let submission = model.reportSubmission, submission != .sending {
                    outcome(submission)
                        .transition(.modalStep(forward: true))
                } else if let node, let path {
                    VStack(alignment: .leading, spacing: 0) {
                        body(of: node, path: path)
                    }
                    .id(node.id)
                    .transition(.modalStep(forward: isGoingForward))
                } else {
                    loading
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: Self.maximumHeight)
        .animation(motion.reposition, value: path?.currentNodeID)
        .animation(motion.reposition, value: model.reportSubmission)
        .onChange(of: path?.nodeIDs.count) { old, new in
            isGoingForward = (new ?? 0) >= (old ?? 0)
        }
        // Started when the tree lands rather than in the body: a body that seeds
        // state runs every render and would reset the walk on every keystroke
        // anywhere in the window.
        .task(id: menu?.rootNodeID) {
            guard path == nil, let root = menu?.rootNodeID else { return }
            path = ReportPath(root: root)
        }
        // A node marked auto-submit files as soon as it is reached — Discord
        // uses it for the two signal-only categories, which are collected and
        // never answered.
        .task(id: node?.id) {
            guard let node, node.isAutoSubmit, autoSubmitted != node.id, let path else { return }
            autoSubmitted = node.id
            model.submitReport(path: path)
        }
    }

    // MARK: Chrome

    private var loading: some View {
        VStack(spacing: Spacing.snug) {
            ProgressView().controlSize(.small)
            Text("Fetching the report categories…")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.section)
        .padding(.bottom, Spacing.group)
    }

    /// What is being reported, drawn as itself.
    ///
    /// A message and a person are one quoted row; a board tile is the tile —
    /// see `ReportPreview`. The tile is drawn on the app's own raised surface
    /// rather than on the person's theme: this sheet is the app asking a
    /// question, and washing it in the reported account's colours would put
    /// their branding around the control that reports them.
    @ViewBuilder
    private var preview: some View {
        switch request.preview {
        case .quoted(let message):
            QuotedMessageRow(message: message)
        case .widget(let tile):
            BoardTilePreview(tile: tile)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: One node

    @ViewBuilder
    private func body(of node: ReportNode, path: ReportPath) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.margin) {
                if node.elements.contains(.subjectPreview) {
                    preview
                }
                if let info = node.info {
                    Callout(text: info)
                }
                if node.elements.contains(.breadcrumbs), !path.labels.isEmpty {
                    ReportTrail(labels: path.labels)
                }
                ForEach(Array(node.elements.enumerated()), id: \.offset) { _, element in
                    switch element {
                    case .checkbox(let name, let options):
                        CheckboxGroup(
                            options: options,
                            isChosen: { path.isChosen($0, in: name) },
                            toggle: { value in self.path?.toggle(value, in: name) }
                        )
                    case .externalLink(let text, let url):
                        Button { openURL(url) } label: {
                            HStack(spacing: Spacing.base) {
                                Text(text)
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(Palette.accent)
                        }
                        .buttonStyle(.plain)
                    case .subjectPreview, .breadcrumbs, .followUp, .decoration:
                        EmptyView()
                    }
                }
                if !node.children.isEmpty {
                    ChoiceList(choices: node.children) { choice in
                        self.path?.push(choice.nodeID, label: choice.label)
                    }
                }
            }
            .padding(.horizontal, Spacing.group)
            .padding(.bottom, Spacing.margin)
        }
        .scrollBounceBehavior(.basedOnSize)
        .softScrollEdgesVertical()

        footer(of: node, path: path)
    }

    @ViewBuilder
    private func footer(of node: ReportNode, path: ReportPath) -> some View {
        let isSending = model.reportSubmission == .sending
        GlassEffectContainer(spacing: Spacing.snug) {
            HStack(spacing: Spacing.snug) {
                if path.canGoBack {
                    ModalButton(title: "Back", symbolName: "chevron.left", role: .secondary) { self.path?.pop() }
                }
                Spacer(minLength: 0)

                switch node.button {
                case .submit:
                    // **The act's colour, not Discord's red**: a report is
                    // chosen, not stumbled into (D11b). It cannot be taken
                    // back, so it takes no Return.
                    ModalButton(
                        title: "Submit Report",
                        symbolName: "paperplane.fill",
                        role: .act,
                        isIrreversible: true,
                        isWorking: isSending
                    ) {
                        model.submitReport(path: path)
                    }
                    .disabled(!path.satisfies(node))

                case .next(let target):
                    ModalButton(title: "Continue", symbolName: "arrow.right", role: .act) {
                        self.path?.push(target, label: nil)
                    }
                    .disabled(!path.satisfies(node))

                case .done, .cancel, .none:
                    // A node with children needs no button: each child is its own
                    // row. One with neither is an end, and Done is what ends it.
                    if node.children.isEmpty {
                        ModalButton(title: "Done", symbolName: "checkmark", role: .act) { model.dismissReport() }
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.margin)
        .padding(.top, Spacing.snug)
    }

    // MARK: After it lands

    @ViewBuilder
    private func outcome(_ state: ReportSubmissionState) -> some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            switch state {
            case .succeeded:
                Callout(
                    text: "Thanks — this is with Discord's safety team now.",
                    symbolName: "checkmark.circle.fill",
                    tint: Palette.affirmative
                )
                // **The follow-ups this client can actually honour.** Discord's
                // acknowledgement node offers block, ignore and delete beside
                // upsells for its own settings; the upsells are dropped rather
                // than drawn as controls that answer nothing — §5.5.
                followUps
            case .failed(let reason):
                Callout(
                    text: reason,
                    symbolName: "exclamationmark.triangle.fill",
                    tint: Palette.destructive
                )
            case .sending:
                EmptyView()
            }
            HStack {
                Spacer()
                ModalButton(title: "Done", symbolName: "checkmark", role: .act) { model.dismissReport() }
            }
        }
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.group)
    }

    @ViewBuilder
    private var followUps: some View {
        if let userID = reportedUserID, let actions = model.userActions(for: userID) {
            VStack(spacing: 0) {
                FollowUpRow(
                    title: actions.isBlocked ? "Unblock this person" : "Block this person",
                    symbolName: "hand.raised.fill",
                    isBusy: actions.isBusy
                ) { model.setBlocked(!actions.isBlocked, userID: userID) }
                CardDivider()
                FollowUpRow(
                    title: actions.isIgnored ? "Stop ignoring" : "Ignore this person",
                    symbolName: "speaker.slash.fill",
                    isBusy: actions.isBusy
                ) { model.setIgnored(!actions.isIgnored, userID: userID) }
            }
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip, style: .continuous))
        }
    }

    /// Who the report is about. A message report is about its author, which the
    /// subject does not name — so it is resolved through the store rather than
    /// carried twice.
    private var reportedUserID: UserID? {
        switch request.subject {
        case .user(let userID, _): userID
        case .message(let messageID, let channelID), .firstDirectMessage(let messageID, let channelID):
            model.message(messageID, in: channelID)?.authorID
        // A widget report names its owner directly — the acknowledgement's
        // block and ignore act on the person whose board it is.
        case .widget(_, let userID): userID
        }
    }
}

// MARK: - Parts

/// The path taken so far, on the summary screen.
private struct ReportTrail: View {
    var labels: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Report category")
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.tertiary)
                .textCase(.uppercase)
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 4, height: 4)
                    Text(label)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The rows a node's children become.
private struct ChoiceList: View {
    var choices: [ReportChoice]
    var choose: (ReportChoice) -> Void

    @Environment(\.motion) private var motion
    @State private var hovered: Int?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                if index > 0 { CardDivider() }
                Button { choose(choice) } label: {
                    HStack(spacing: Spacing.snug) {
                        Text(choice.label)
                            .font(.system(.body))
                            .foregroundStyle(Ink.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Spacing.base)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Ink.tertiary)
                    }
                    .padding(.horizontal, Spacing.margin)
                    .padding(.vertical, Spacing.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(hovered == choice.nodeID ? Palette.hoverFill : .clear)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { isInside in
                    let next = isInside ? choice.nodeID : (hovered == choice.nodeID ? nil : hovered)
                    guard next != hovered else { return }
                    hovered = next
                }
            }
        }
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip, style: .continuous))
        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        .animation(motion.fadeQuick, value: hovered)
    }
}

/// A node's multi-select.
private struct CheckboxGroup: View {
    var options: [ReportOption]
    var isChosen: (String) -> Bool
    var toggle: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { CardDivider() }
                Button { toggle(option.value) } label: {
                    HStack(spacing: Spacing.snug) {
                        Image(symbol: isChosen(option.value) ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14))
                            .foregroundStyle(
                                isChosen(option.value)
                                    ? AnyShapeStyle(Palette.accent)
                                    : AnyShapeStyle(Ink.tertiary)
                            )
                        Text(option.label)
                            .font(.system(.body))
                            .foregroundStyle(Ink.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Spacing.margin)
                    .padding(.vertical, Spacing.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip, style: .continuous))
        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
    }
}

/// One thing the acknowledgement offers to do next.
private struct FollowUpRow: View {
    var title: String
    var symbolName: String
    var isBusy: Bool
    var act: () -> Void

    var body: some View {
        Button(action: act) {
            HStack(spacing: Spacing.snug) {
                Image(symbol: symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(.body))
                Spacer(minLength: 0)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, Spacing.margin)
            .padding(.vertical, Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }
}
