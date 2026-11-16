extension Set {
    /// Whether the set holds an element, as something a toggle can bind to:
    /// `$chosen[contains: role.id]` (swiftui-pro: a labeled subscript, not a
    /// `Binding(get:set:)` built in `body`).
    subscript(contains element: Element) -> Bool {
        get { contains(element) }
        set {
            if newValue {
                insert(element)
            } else {
                remove(element)
            }
        }
    }
}
