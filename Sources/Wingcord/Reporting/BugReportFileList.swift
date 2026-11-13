import SwiftUI
import WingcordCore

/// The report's files, one row each — what it is, how big — and the total.
struct BugReportFileList: View {
    var contents: BugReportContents
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(contents.files) { file in
                        BugReportFileRow(file: file, isSelected: file.name == selection) {
                            selection = file.name
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Text("\(contents.files.count) files, \(LogMessage.describe(bytes: Int64(contents.totalBytes))) before compression")
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, Spacing.base)
        }
    }
}

/// A file: its kind's symbol, its name, its size and what it is.
struct BugReportFileRow: View {
    var file: BugReportContents.File
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: Spacing.base) {
                Image(systemName: symbolName)
                    .font(.system(.body))
                    .foregroundStyle(isSelected ? Ink.primary : Ink.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Spacing.tight) {
                        Text(file.name)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Spacing.tight)
                        Text(LogMessage.describe(bytes: Int64(file.data.count)))
                            .font(.system(.caption))
                            .monospacedDigit()
                            .foregroundStyle(Ink.secondary)
                    }
                    Text(file.caption)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Radius.row).fill(Palette.selectionFill)
                }
            }
            .contentShape(.rect(cornerRadius: Radius.row))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbolName: String {
        switch file.kind {
        case .text: "doc.text"
        case .json: "curlybraces"
        case .image: "photo"
        }
    }
}
