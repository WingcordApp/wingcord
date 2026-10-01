import Foundation

/// A form an application asked the reader to fill in — Discord's interaction
/// modal, raised by `INTERACTION_MODAL_CREATE` in answer to a command or a
/// button.
///
/// **Its fields are Discord's own parse of the payload** (`transformComponent`
/// in its client): text inputs, labels around a field, text, string selects,
/// radio groups, checkbox groups and checkboxes. File uploads and the
/// member, role and channel pickers need surfaces this client does not have
/// yet; they are kept as `unsupported` so the form still submits their empty
/// answer, as Discord's own does for a field left alone.
public struct InteractionModal: Identifiable, Hashable, Sendable {
    /// The interaction's own id, sent back as `data.id`.
    public var id: String
    public var customID: String
    public var title: String
    public var channelID: ChannelID
    public var applicationID: ApplicationID
    public var applicationName: String?
    public var applicationIconHash: String?
    /// The nonce of the interaction that raised it.
    public var nonce: String?
    public var fields: [Field]

    public init(
        id: String,
        customID: String,
        title: String,
        channelID: ChannelID,
        applicationID: ApplicationID,
        applicationName: String? = nil,
        applicationIconHash: String? = nil,
        nonce: String? = nil,
        fields: [Field]
    ) {
        self.id = id
        self.customID = customID
        self.title = title
        self.channelID = channelID
        self.applicationID = applicationID
        self.applicationName = applicationName
        self.applicationIconHash = applicationIconHash
        self.nonce = nonce
        self.fields = fields
    }

    public indirect enum Field: Hashable, Sendable {
        /// An action row (1): the old form's wrapper around one input.
        case row([Field])
        /// A label (18) over one field, with an optional line under it.
        case label(text: String, description: String?, field: Field)
        /// Text (10), in Discord's markdown.
        case text(String)
        case textInput(TextInput)
        case select(SelectMenu)
        case radioGroup(Choice)
        case checkboxGroup(Choice)
        case checkbox(customID: String, isDefault: Bool)
        /// A field this client has no surface for — a file upload, a picker.
        case unsupported(type: Int, customID: String?)
    }

    public struct TextInput: Hashable, Sendable {
        public var customID: String
        /// The old form's label, on the input itself; a label component's
        /// replaces it.
        public var label: String?
        public var isParagraph: Bool
        public var value: String?
        public var placeholder: String?
        public var isRequired: Bool
        public var minLength: Int?
        public var maxLength: Int?

        public init(
            customID: String, label: String? = nil, isParagraph: Bool = false, value: String? = nil,
            placeholder: String? = nil, isRequired: Bool = false, minLength: Int? = nil, maxLength: Int? = nil
        ) {
            self.customID = customID
            self.label = label
            self.isParagraph = isParagraph
            self.value = value
            self.placeholder = placeholder
            self.isRequired = isRequired
            self.minLength = minLength
            self.maxLength = maxLength
        }

        /// Whether `text` is an answer the application will take.
        public func accepts(_ text: String) -> Bool {
            if text.isEmpty { return !isRequired }
            if let minLength, text.count < minLength { return false }
            if let maxLength, text.count > maxLength { return false }
            return true
        }
    }

    /// A radio group (one) or a checkbox group (any number within bounds).
    public struct Choice: Hashable, Sendable {
        public var customID: String
        public var options: [SelectMenu.Option]
        public var minValues: Int?
        public var maxValues: Int?
        public var isRequired: Bool

        public init(
            customID: String, options: [SelectMenu.Option],
            minValues: Int? = nil, maxValues: Int? = nil, isRequired: Bool = false
        ) {
            self.customID = customID
            self.options = options
            self.minValues = minValues
            self.maxValues = maxValues
            self.isRequired = isRequired
        }
    }

    /// What the reader has put in one field.
    public enum Answer: Hashable, Sendable {
        case text(String)
        case values([String])
        case flag(Bool)
    }

    /// Every field that takes an answer, flattened out of rows and labels.
    public var inputs: [Field] {
        func walk(_ field: Field) -> [Field] {
            switch field {
            case .row(let children): children.flatMap(walk)
            case .label(_, _, let inner): walk(inner)
            case .text: []
            default: [field]
            }
        }
        return fields.flatMap(walk)
    }

    /// The answers the form opens with: an input's prefilled value, the
    /// options marked default, a checkbox's default.
    public var initialAnswers: [String: Answer] {
        var answers: [String: Answer] = [:]
        for field in inputs {
            switch field {
            case .textInput(let input): answers[input.customID] = .text(input.value ?? "")
            case .select(let menu): answers[menu.customID] = .values(menu.options.filter(\.isDefault).map(\.value))
            case .radioGroup(let choice), .checkboxGroup(let choice):
                answers[choice.customID] = .values(choice.options.filter(\.isDefault).map(\.value))
            case .checkbox(let customID, let isDefault): answers[customID] = .flag(isDefault)
            default: break
            }
        }
        return answers
    }

    /// Whether the form may be sent: every required field answered, and every
    /// answer within its field's bounds.
    public func isComplete(_ answers: [String: Answer]) -> Bool {
        inputs.allSatisfy { field in
            switch field {
            case .textInput(let input):
                guard case .text(let text) = answers[input.customID] ?? .text("") else { return false }
                return input.accepts(text)
            case .select(let menu):
                let count = Self.values(answers[menu.customID]).count
                return count == 0 ? menu.minValues == 0 : menu.accepts(Set(Self.values(answers[menu.customID])))
            case .radioGroup(let choice):
                return !choice.isRequired || Self.values(answers[choice.customID]).count == 1
            case .checkboxGroup(let choice):
                let count = Self.values(answers[choice.customID]).count
                if count == 0 { return !choice.isRequired && (choice.minValues ?? 0) == 0 }
                return count >= (choice.minValues ?? 0) && count <= (choice.maxValues ?? choice.options.count)
            default:
                return true
            }
        }
    }

    public static func values(_ answer: Answer?) -> [String] {
        if case .values(let values) = answer { return values }
        return []
    }
}
