import SwiftUI

// MARK: - Connect your Domain
//
// The one connection with no browser redirect: Discord proves a personal
// domain in-app, by asking the reader to publish a token as a DNS TXT record
// or a file at `/.well-known/discord`, then checking for it. Built the same
// way the other two raised sheets in this app are — `GameServerConnectSheet`,
// `ServerRulesSheet` — a floating card supplying its own material, not this
// window's glass: it sits above the settings pane rather than inside it.

struct ConnectDomainSheet: View {
    var sheet: DomainConnectionSheet
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var domainText = ""
    @FocusState private var isFocused: Bool

    private static let width: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
            footer
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Ink.quaternary, lineWidth: 1)
        }
        .presentationBackground(.clear)
        .animation(motion.standard, value: sheet.phase)
        .task { isFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Connect your Domain")
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(Ink.primary)
            Text(currentProof == nil
                ? "Verify ownership and show it off on your profile."
                : "Publish this token, then press Verify.")
                .font(.system(.callout))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    @ViewBuilder
    private var content: some View {
        if let error = currentError {
            Text(error)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Palette.presenceDoNotDisturb)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.group)
                .padding(.bottom, Spacing.margin)
        }
        if let proof = currentProof {
            VStack(alignment: .leading, spacing: Spacing.base) {
                DomainMethodCard(
                    title: "DNS record",
                    rows: [
                        ("Name", "_discord.\(sheet.domain)"),
                        ("Type", "TXT"),
                    ],
                    content: proof
                )
                DomainMethodCard(
                    title: "Website file",
                    rows: [("Address", "https://\(sheet.domain)/.well-known/discord")],
                    content: proof
                )
                Text("Either one works. A DNS record can take a few minutes to propagate.")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.group)
            .padding(.bottom, Spacing.margin)
        } else {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Domain")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                TextField("example.com", text: $domainText)
                    .textFieldStyle(.plain)
                    .font(.system(.callout))
                    .foregroundStyle(Ink.primary)
                    .padding(.horizontal, Spacing.snug)
                    .frame(height: Metrics.control + Spacing.base)
                    .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.row, style: .continuous))
                    .focused($isFocused)
                    .disabled(isSubmitting)
                    .onSubmit(submit)
            }
            .padding(.horizontal, Spacing.group)
            .padding(.bottom, Spacing.margin)
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.base) {
            SurfaceQuietButton(title: currentProof == nil ? "Cancel" : "Close", systemImage: nil) {
                model.sessionController.dismissDomainConnectionSheet()
            }
            Spacer(minLength: 0)
            if isVerifying || isSubmitting {
                ProgressView().controlSize(.small)
            }
            if currentProof == nil {
                SurfaceFilledButton(title: "Continue", systemImage: nil, action: submit)
                    .disabled(domainText.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                    .opacity(isSubmitting ? 0.45 : 1)
            } else {
                SurfaceFilledButton(title: "Verify", systemImage: nil) {
                    model.sessionController.retryDomainVerification()
                }
                .disabled(isVerifying)
                .opacity(isVerifying ? 0.45 : 1)
            }
        }
        .padding(Spacing.group)
    }

    private func submit() {
        model.sessionController.submitDomainConnection(domainText)
    }

    private var currentProof: String? {
        switch sheet.phase {
        case .pending(let proof, _), .verifying(let proof): proof
        case .enteringDomain, .submitting, .failed: nil
        }
    }

    private var currentError: String? {
        switch sheet.phase {
        case .pending(_, let lastError): lastError
        case .failed(let message): message
        case .enteringDomain, .submitting, .verifying: nil
        }
    }

    private var isSubmitting: Bool {
        if case .submitting = sheet.phase { return true }
        return false
    }

    private var isVerifying: Bool {
        if case .verifying = sheet.phase { return true }
        return false
    }
}

/// One verification method: its labelled rows, and a single Copy for the
/// token every method needs — the row worth a button, where the others are
/// short enough to just select.
private struct DomainMethodCard: View {
    var title: String
    var rows: [(String, String)]
    var content: String

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.secondary)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ForEach(rows, id: \.0) { label, value in
                    FieldRow(label: label, value: value)
                }
                HStack(spacing: Spacing.snug) {
                    FieldRow(label: "Content", value: content)
                    CopyButton(value: content, didCopy: $didCopy)
                }
            }
        }
        .padding(Spacing.snug)
        .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.card, style: .continuous))
    }
}

private struct FieldRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Text(label)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Ink.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
