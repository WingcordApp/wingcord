import Foundation

/// An optional field that is sent as `null` when it is nil, never left out.
///
/// **A synthesised `Encodable` drops nil keys**, and on Discord's settings
/// routes an absent key means "leave it as it is". So every control that
/// *clears* something — "No System Messages", "No Inactive Channel", a
/// widget's "No Invite", a role going back to one colour — sent nothing and
/// changed nothing, while the save indicator said "Saved". Discord's own
/// bodies carry the `null`. Mark a field with this where nil means "clear it".
@propertyWrapper
struct ExplicitNull<Value: Encodable & Sendable>: Encodable, Sendable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}
