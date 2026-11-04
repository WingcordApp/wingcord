import SwiftUI
import WingcordCore

/// Whether New Message is up — asked for from the `+⌄` menu and File › New
/// Message, which cannot host a sheet of their own.
@Observable
@MainActor
final class NewMessageRequest {
    static let shared = NewMessageRequest()
    var isShown = false
}

/// Messages' New Message (REDESIGN.md R12): a name typed, a friend picked, and
/// the conversation with them — made where there is none yet.
struct NewMessageSheet: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var highlighted: UserID?

    private struct Person: Identifiable, Hashable {
        var id: UserID
        var name: String
        var handle: String
        var avatarURL: URL?
        var monogram: String
        var status: PresenceStatus
    }

    var body: some View {
        let people = matches
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(title: "New Message", close: { NewMessageRequest.shared.isShown = false })
            picker(people)
                .padding(.horizontal, Spacing.group)
                .padding(.bottom, Spacing.group)
        }
        .frame(width: 420)
        .onChange(of: query) { _, _ in highlighted = nil }
    }

    private func picker(_ people: [Person]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            // The system's search field on glass, leading the list it picks
            // from: the arrows move through it and Return opens the one lit.
            SearchField(
                prompt: "To: a friend's name",
                text: $query,
                onMove: { move($0, in: people) },
                onSubmit: { if let first = highlighted ?? people.first?.id { open(first) } }
            )
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(people) { person in
                        Button { open(person.id) } label: {
                            HStack(spacing: Spacing.snug) {
                                AvatarView(url: person.avatarURL, monogram: person.monogram, side: 30)
                                    .overlay(alignment: .bottomTrailing) {
                                        PresenceDot(status: person.status, side: 10).offset(x: 2, y: 2)
                                    }
                                Text(person.name)
                                    .font(.system(.body, weight: .semibold))
                                    .foregroundStyle(Ink.primary)
                                Text(person.handle)
                                    .font(.system(.callout))
                                    .foregroundStyle(Ink.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Spacing.tight)
                            .padding(.vertical, 5)
                            .background {
                                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                                    .fill(person.id == (highlighted ?? people.first?.id) ? Palette.hoverFill : .clear)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { highlighted = person.id } }
                    }
                }
            }
            .frame(height: 280)
        }
    }

    /// The reader's friends, by name, narrowed by what is typed.
    private var matches: [Person] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.relationships.compactMap { userID, relationship -> Person? in
            guard relationship == .friend, let user = model.users[userID] else { return nil }
            let name = model.friendNicknames[userID] ?? user.preferredName
            if !needle.isEmpty, !name.lowercased().contains(needle), !user.handle.lowercased().contains(needle) {
                return nil
            }
            return Person(
                id: userID,
                name: name,
                handle: user.handle,
                avatarURL: model.avatarURL(for: user, side: 30),
                monogram: user.monogram,
                status: model.presenceStatus(of: userID)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func move(_ step: Int, in people: [Person]) {
        guard !people.isEmpty else { return }
        let current = people.firstIndex { $0.id == (highlighted ?? people.first?.id) } ?? 0
        highlighted = people[min(max(current + step, 0), people.count - 1)].id
    }

    private func open(_ userID: UserID) {
        NewMessageRequest.shared.isShown = false
        model.messagePerson(userID)
    }
}
