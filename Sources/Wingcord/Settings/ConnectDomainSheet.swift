import SwiftUI

// MARK: - Connect your Domain
//
// The one connection with no browser redirect: Discord proves a personal
// domain in-app, by asking the reader to publish a token as a DNS TXT record
// or a file at `/.well-known/discord`, then checking for it. A plain system
// sheet, like every other in the app: the system's ground, Cancel on Escape
// and the step's action on Return.

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
        GlassEffectContainer(spacing: Spacing.snug) {
            HStack(spacing: Spacing.snug) {
                ModalButton(title: currentProof == nil ? "Cancel" : "Close", symbolName: "xmark", role: .cancel) {
                    model.sessionController.dismissDomainConnectionSheet()
                }
                Spacer(minLength: 0)
                if currentProof == nil {
                    ModalButton(title: "Continue", symbolName: "arrow.right", role: .act, isWorking: isSubmitting, action: submit)
                        .disabled(domainText.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    ModalButton(title: "Verify", symbolName: "checkmark.seal", role: .act, isWorking: isVerifying) {
                        model.sessionController.retryDomainVerification()
                    }
                }
            }
        }
        .padding(Spacing.margin)
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
