import AppKit
import SwiftUI
import WingcordCore

/// Discord's "Change language" (`684519`'s `eT`): the `</>` in a text
/// preview's footer, opening a list of highlight.js's languages under
/// "Search languages" — the list Discord shows without its LanguageSelect
/// experiment (`639169.Q`, `PlaintextPreview.languages`).
///
/// **A popover, as Discord's popout is**, and like every popover here it
/// paints nothing of its own (`INVARIANTS.md` §4.9): the field is the system's
/// search field with its own bezel — not the glass capsule `SearchField` wears
/// in a window, which inside a popover's glass would be a flat slab — and the
/// list is the system's `List`.
struct CodeLanguageButton: View {
    var language: String
    var choose: (String) -> Void

    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
        }
        .buttonStyle(.borderless)
        .help("Change language")
        .accessibilityLabel(Text("Change language"))
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            CodeLanguageList(current: language) { picked in
                isOpen = false
                choose(picked)
            }
        }
    }
}

/// The search field over the list. Typing filters; ↑ and ↓ move through what
/// is left; Return takes the one marked; Escape closes the popover.
private struct CodeLanguageList: View {
    var current: String
    var pick: (String) -> Void

    @State private var query = ""
    @State private var marked: String?

    /// Discord's popout is at most 176 wide; the system's list rows want a
    /// little more for their insets.
    private static let width: CGFloat = 200
    private static let height: CGFloat = 300

    private var matches: [String] {
        CodeLanguageFilter.matches(query, in: PlaintextPreview.languages)
    }

    var body: some View {
        let matches = matches
        VStack(spacing: 0) {
            LanguageSearchField(
                text: $query,
                move: { step in move(by: step, in: matches) },
                submit: { if let marked = marked ?? matches.first { pick(marked) } }
            )
            .padding(Spacing.snug)

            ScrollViewReader { proxy in
                List(matches, id: \.self, selection: Binding(
                    get: { marked },
                    set: { picked in
                        guard let picked else { return }
                        pick(picked)
                    }
                )) { name in
                    HStack {
                        Text(verbatim: name)
                        Spacer(minLength: 0)
                        if name == current {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Palette.accent)
                                .accessibilityLabel(Text("Current"))
                        }
                    }
                    .id(name)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: marked) { _, name in
                    guard let name else { return }
                    proxy.scrollTo(name)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
            .overlay {
                if matches.isEmpty {
                    Text("No languages match.")
                        .font(.subheadline)
                        .foregroundStyle(Ink.secondary)
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
        .onChange(of: query) { marked = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Change language"))
    }

    private func move(by step: Int, in matches: [String]) {
        guard !matches.isEmpty else { return }
        let index = marked.flatMap { matches.firstIndex(of: $0) }
        let next = index.map { min(max($0 + step, 0), matches.count - 1) } ?? (step > 0 ? 0 : matches.count - 1)
        marked = matches[next]
    }
}

/// What the list shows for what was typed: every name containing it, those
/// that start with it first, each group in Discord's order.
nonisolated enum CodeLanguageFilter {
    static func matches(_ query: String, in languages: [String]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return languages }
        var leading: [String] = []
        var inner: [String] = []
        for name in languages {
            let lower = name.lowercased()
            if lower.hasPrefix(needle) {
                leading.append(name)
            } else if lower.contains(needle) {
                inner.append(name)
            }
        }
        return leading + inner
    }
}

/// The system's search field, bezelled, taking the arrows and Return for the
/// list under it.
private struct LanguageSearchField: NSViewRepresentable {
    @Binding var text: String
    var move: (Int) -> Void
    var submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search languages"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.controlSize = .large
        // The caret is in the field as the popover opens, as Discord's is.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: LanguageSearchField

        init(_ parent: LanguageSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                parent.move(1)
            case #selector(NSResponder.moveUp(_:)):
                parent.move(-1)
            case #selector(NSResponder.insertNewline(_:)):
                parent.submit()
            default:
                return false
            }
            return true
        }
    }
}
