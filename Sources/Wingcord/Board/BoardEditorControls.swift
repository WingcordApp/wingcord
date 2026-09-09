import SwiftUI
import WingcordCore
import WingcordNet

// The three controls the board editor raises: a tag list, a game search, and
// the sheet that adds a widget.

/// Choosing a game's tags.
///
/// **Three groups with two different arities, and the wire is what says so.**
/// A game carries at most one skill — captured, every board sends a single
/// `better_than_you` or `intermediate` and never two — while feelings and
/// social tags are a set: one capture sends eleven of them on one game. So skill
/// is a radio list with a None, and the other two are checkboxes.
struct GameTagPicker: View {
    var tags: [GameWidgetTag]
    var update: ([GameWidgetTag]) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.margin) {
                skillGroup
                group("Rating", GameWidgetTag.Feeling.allCases.map(GameWidgetTag.feeling))
                group("Looking for", GameWidgetTag.Social.allCases.map(GameWidgetTag.social))
            }
            .padding(Spacing.margin)
        }
        .scrollIndicators(.never)
        .frame(width: 240)
        .frame(maxHeight: 380)
    }

    private var currentSkill: GameWidgetTag.Skill? {
        tags.compactMap { if case .skill(let value) = $0 { value } else { nil } }.first
    }

    private var skillGroup: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            heading("Skill level")
            radioRow(title: "None", isOn: currentSkill == nil) { setSkill(nil) }
            ForEach(GameWidgetTag.Skill.allCases, id: \.self) { skill in
                radioRow(title: skill.title, isOn: currentSkill == skill) { setSkill(skill) }
            }
        }
    }

    private func group(_ title: String, _ options: [GameWidgetTag]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            heading(title)
            ForEach(Array(options.enumerated()), id: \.offset) { _, tag in
                Toggle(isOn: Binding(
                    get: { tags.contains(tag) },
                    set: { isOn in
                        var next = tags
                        if isOn {
                            next.append(tag)
                        } else {
                            next.removeAll { $0 == tag }
                        }
                        update(next)
                    }
                )) {
                    Text(tag.title)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.primary)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(Typeface.sectionHeader)
            .foregroundStyle(InkColor.tertiary)
            .textCase(.uppercase)
            .tracking(0.9)
    }

    private func radioRow(title: String, isOn: Bool, select: @escaping () -> Void) -> some View {
        Button(action: select) {
            HStack(spacing: Spacing.base) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? Color.accentColor : InkColor.tertiary)
                Text(title)
                    .font(.system(.subheadline))
                    .foregroundStyle(InkColor.primary)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// **One skill replaces the other**, which is what makes this a radio list
    /// rather than a checkbox group that happens to be used one at a time.
    private func setSkill(_ skill: GameWidgetTag.Skill?) {
        var next = tags.filter { if case .skill = $0 { false } else { true } }
        if let skill { next.insert(.skill(skill), at: 0) }
        update(next)
    }
}

// MARK: - Finding a game

/// The type-ahead behind a widget's `+`.
///
/// **`GET /games/autocomplete`, debounced, and cancelled on every keystroke.**
/// The route answers a name, an id and at most an icon; the full record is
/// fetched only once something is chosen, by the board's own resolver. A request
/// per character against a catalogue this size is a request per character, so
/// the previous one is cancelled rather than left to land out of order.
struct GameSearchField: View {
    var add: (GameSummary) -> Void
    var cancel: () -> Void

    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [GameSummary] = []
    @State private var search: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .focused($isFocused)
                .padding(Spacing.base)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.skeletonPlate)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1)
                }
                .onExitCommand(perform: cancel)
                .onChange(of: query) { _, text in
                    search?.cancel()
                    guard text.count >= 1 else {
                        results = []
                        return
                    }
                    search = Task {
                        // A beat, so a fast typist makes one request rather than
                        // one per character.
                        try? await Task.sleep(for: .milliseconds(180))
                        guard !Task.isCancelled else { return }
                        let hits = (try? await model.sessionController.rest.searchGames(text)) ?? []
                        guard !Task.isCancelled else { return }
                        results = hits
                    }
                }

            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results.prefix(8)) { game in
                        Button { add(game) } label: {
                            HStack(spacing: Spacing.base) {
                                Text(game.name)
                                    .font(.system(.subheadline))
                                    .foregroundStyle(InkColor.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Spacing.base)
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, Spacing.tight)
                .background {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Palette.surfaceRaised)
                }
            }
        }
        .onAppear { isFocused = true }
        .onDisappear { search?.cancel() }
    }
}

// MARK: - Adding a widget

/// "Add Profile Widget", with the kinds the reader does not already have.
///
/// **A kind already on the board is not offered.** The route accepts at most one
/// widget of each list kind, so a second "Games I Like" is a save that fails
/// whole — the same reason the `+` disappears at a list's cap.
struct AddWidgetSheet: View {
    var existing: Set<ProfileWidgetKind>
    var add: (ProfileWidgetKind) -> Void
    var dismiss: () -> Void

    /// The four list widgets, in the order Discord's own sheet offers them. The
    /// application widget is deliberately absent: it is created by linking a
    /// game account, not by choosing it here, and this client has no linking
    /// flow — see `HANDOFF.md`.
    private static let offered: [ProfileWidgetKind] = [
        // **"Create your own" leads, as it does in Discord's own sheet.** It is
        // the only kind that is not a list of games, and the only one where the
        // reader supplies everything.
        .personal,
        .currentGames, .playedGames, .wantToPlayGames, .favouriteGames,
    ]

    private var available: [ProfileWidgetKind] {
        Self.offered.filter { !existing.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add Profile Widget")
                    .font(.system(.title3, weight: .bold))
                    .foregroundStyle(InkColor.primary)
                Spacer(minLength: Spacing.margin)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(InkColor.secondary)
                        .frame(width: Metrics.control, height: Metrics.control)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }
            .padding(.horizontal, Spacing.group)
            .padding(.vertical, Spacing.margin)

            Divider().overlay(Palette.railHairline)

            if available.isEmpty {
                Text("You already have every widget this client can add.")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .padding(Spacing.group)
            } else {
                VStack(spacing: Spacing.snug) {
                    ForEach(available, id: \.self) { kind in
                        Button { add(kind) } label: {
                            HStack(spacing: Spacing.snug) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.title)
                                        .font(.system(.subheadline, weight: .semibold))
                                        .foregroundStyle(InkColor.primary)
                                    if let limit = kind.gameLimit {
                                        Text(
                                            limit == 1
                                                ? "Choose 1 game"
                                                : "Add up to \(limit) games"
                                        )
                                        .font(.system(size: 11))
                                        .foregroundStyle(InkColor.tertiary)
                                    } else if kind == .personal {
                                        Text("A cover and up to four slots, all yours")
                                            .font(.system(size: 11))
                                            .foregroundStyle(InkColor.tertiary)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(InkColor.secondary)
                            }
                            .padding(Spacing.margin)
                            .background {
                                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                    .fill(Palette.skeletonPlate)
                            }
                            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Spacing.group)
            }
        }
        .frame(width: 420)
        .background(Palette.surface)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
    }
}

// MARK: - Shapes the editor needs from a widget

extension ProfileWidget.Content {
    /// Which kind this is, or nil for one this client cannot name.
    var kind: ProfileWidgetKind? {
        switch self {
        case .favouriteGames: .favouriteGames
        case .currentGames: .currentGames
        case .playedGames: .playedGames
        case .wantToPlayGames: .wantToPlayGames
        case .application: .application
        case .personal: .personal
        case .unknown: nil
        }
    }

    /// The games inside, or none for a widget that holds none.
    var games: [ProfileWidgetGame] {
        switch self {
        case .favouriteGames(let games), .currentGames(let games),
             .playedGames(let games), .wantToPlayGames(let games):
            games
        case .application, .personal, .unknown:
            []
        }
    }
}

extension ProfileWidgetKind {
    /// A newly added widget, holding nothing yet.
    var emptyContent: ProfileWidget.Content {
        switch self {
        case .favouriteGames: .favouriteGames([])
        case .currentGames: .currentGames([])
        case .playedGames: .playedGames([])
        case .wantToPlayGames: .wantToPlayGames([])
        case .personal: .personal(PersonalWidget())
        // Unreachable from `AddWidgetSheet`, which does not offer it: an
        // application widget is created by linking a game account.
        case .application: .playedGames([])
        }
    }
}
