import SwiftUI

/// Popular Music: top songs, artists and listeners behind one picker.
struct PopularMusicCardView: View {
    var music: PopularMusicCardModel

    @State private var tab: PopularMusicCardModel.Tab = .songs

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            SegmentedPicker(
                options: PopularMusicCardModel.Tab.allCases.map { .init($0, $0.title) },
                selection: $tab,
                fillsWidth: true
            )
            .padding(.horizontal, Spacing.margin)
            .accessibilityLabel(Text("Popular Music views"))
            VStack(spacing: 2) {
                ForEach(music.rows(tab).prefix(5)) { row in
                    PopularMusicRowView(row: row)
                }
            }
            .padding(.horizontal, Spacing.base)
            .id(tab)
            .transition(.opacity)
            if let summary = music.summary {
                Text(summary)
                    .font(.system(.callout))
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, Spacing.margin)
            }
        }
        .padding(.vertical, Spacing.margin)
        .animation(.easeInOut(duration: 0.18), value: tab)
    }
}
