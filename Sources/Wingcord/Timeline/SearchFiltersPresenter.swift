import SwiftUI
import WingcordCore

/// Presents the search filter sheet, once, at the window root.
///
/// The same rule every other raised surface in this app follows — a `.sheet`
/// written inside the panel is evaluated as part of the panel's body on every
/// keystroke of the field above it.
struct SearchFiltersPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        // **Read here, in the modifier's own body**, not inside the closure: the
        // roster fills in from the gateway while the sheet is open, and a read
        // that happens only inside a presentation closure is not a dependency
        // this view is invalidated by.
        let query = model.isSearchFiltersShown ? model.searchFilterQuery : nil
        let people = model.isSearchFiltersShown ? model.searchFilterPeople : []
        let channels = model.isSearchFiltersShown ? model.searchFilterChannels : []

        return content
            .sheet(isPresented: $model.isSearchFiltersShown) {
                if let query {
                    SearchFiltersSheet(
                        query: query,
                        people: people,
                        channels: channels,
                        apply: { applied in
                            model.isSearchFiltersShown = false
                            model.applySearchFilters(applied)
                        },
                        dismiss: { model.isSearchFiltersShown = false }
                    )
                }
            }
    }
}

extension View {
    /// Applied once, at the window root, above `.environment(model)`.
    func presentsSearchFilters() -> some View {
        modifier(SearchFiltersPresenter())
    }
}
