import Foundation

/// An Image + Text widget, resolved for drawing.
struct ImageTextCardModel: Equatable {
    var text: String?
    var imageURL: URL?
    /// A picture picked in this edit and not yet saved.
    var imagePreview: Data?

    var isEmpty: Bool {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imageURL == nil && imagePreview == nil
    }
}
