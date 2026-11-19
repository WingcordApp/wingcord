import Foundation

/// A form an application asked the reader to fill in — Discord's interaction
/// modal, raised by `INTERACTION_MODAL_CREATE` in answer to a command or a
/// button.
///
/// **Its fields are Discord's own parse of the payload** (`transformComponent`
/// in its client): text inputs, labels around a field, text, string selects,
/// member, role, mentionable and channel pickers, file uploads, radio groups,
/// checkbox groups and checkboxes (docs/BETA3.md §2.4). Anything newer stays
/// `unsupported` so the form still submits its empty answer, as Discord's own
/// does for a field left alone.
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
        /// A member, role, mentionable or channel picker.
        case entitySelect(EntitySelect)
        /// Files to send with the form.
        case fileUpload(FileUpload)
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
        /// Files picked for a file upload, sent ahead of the form.
        case files([PickedFile])
    }

    /// A file picked on this Mac for a form's upload.
    public struct PickedFile: Hashable, Sendable, Identifiable {
        public var url: URL
        public var name: String
        public var size: Int

        public var id: URL { url }

        public init(url: URL, name: String, size: Int) {
            self.url = url
            self.name = name
            self.size = size
        }
    }

    /// A member, role, mentionable or channel picker (components 5–8).
    public struct EntitySelect: Hashable, Sendable {
        public enum Kind: Int, Hashable, Sendable {
            case user = 5, role = 6, mentionable = 7, channel = 8
        }

        public var kind: Kind
        public var customID: String
        public var placeholder: String?
        public var minValues: Int
        public var maxValues: Int
        public var isRequired: Bool
        /// The ids chosen when the form opens.
        public var defaultIDs: [String]
        /// The channel kinds a channel picker offers; empty is every kind.
        public var channelTypes: [Int]

        public var isSingle: Bool { maxValues <= 1 }

        public init(
            kind: Kind,
            customID: String,
            placeholder: String? = nil,
            minValues: Int = 1,
            maxValues: Int = 1,
            isRequired: Bool = true,
            defaultIDs: [String] = [],
            channelTypes: [Int] = []
        ) {
            self.kind = kind
            self.customID = customID
            self.placeholder = placeholder
            self.minValues = minValues
            self.maxValues = max(1, maxValues)
            self.isRequired = isRequired
            self.defaultIDs = defaultIDs
            self.channelTypes = channelTypes
        }

        /// Whether `count` choices may be sent: none only when the field is
        /// optional (its `min_values` counts once something is chosen, as in
        /// Discord), otherwise within the bounds.
        public func accepts(_ count: Int) -> Bool {
            if count == 0 { return !isRequired }
            return count >= minValues && count <= maxValues
        }
    }

    /// Files to send with the form (component 19). Discord's defaults: one
    /// file, required.
    public struct FileUpload: Hashable, Sendable {
        public var customID: String
        public var minValues: Int
        public var maxValues: Int
        public var isRequired: Bool

        public init(customID: String, minValues: Int = 1, maxValues: Int = 1, isRequired: Bool = true) {
            self.customID = customID
            self.minValues = minValues
            self.maxValues = max(1, maxValues)
            self.isRequired = isRequired
        }

        public func accepts(_ count: Int) -> Bool {
            if count == 0 { return !isRequired }
            return count >= minValues && count <= maxValues
        }
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
            case .entitySelect(let select): answers[select.customID] = .values(select.defaultIDs)
            case .fileUpload(let upload): answers[upload.customID] = .files([])
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
            case .entitySelect(let select):
                return select.accepts(Self.values(answers[select.customID]).count)
            case .fileUpload(let upload):
                return upload.accepts(Self.files(answers[upload.customID]).count)
            default:
                return true
            }
        }
    }

    public static func values(_ answer: Answer?) -> [String] {
        if case .values(let values) = answer { return values }
        return []
    }

    public static func files(_ answer: Answer?) -> [PickedFile] {
        if case .files(let files) = answer { return files }
        return []
    }
}
