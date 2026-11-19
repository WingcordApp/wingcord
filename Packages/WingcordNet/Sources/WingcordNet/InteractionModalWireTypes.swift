import Foundation
import WingcordCore

// MARK: - Forms an application raises

/// `INTERACTION_MODAL_CREATE`: the fields Discord's dispatcher reads —
/// `id`, `channel_id`, `custom_id`, `application`, `title`, `components`,
/// `nonce` (web `d4c7976eccf337f1`).
struct InteractionModalDTO: Decodable, Sendable {
    struct ApplicationDTO: Decodable, Sendable {
        var id: ApplicationID
        var name: String?
        var icon: String?
    }

    var id: String
    var channel_id: ChannelID
    var custom_id: String
    var title: String?
    var nonce: String?
    var application: ApplicationDTO
    var components: [ComponentDTO]?

    var domain: InteractionModal {
        InteractionModal(
            id: id,
            customID: custom_id,
            title: title ?? "",
            channelID: channel_id,
            applicationID: application.id,
            applicationName: application.name,
            applicationIconHash: application.icon,
            nonce: nonce,
            fields: (components ?? []).compactMap(\.modalField)
        )
    }
}

extension ComponentDTO {
    /// One field of a form, read as Discord's own `transformComponent` reads
    /// it: a text input's `style`, `label`, `value`, `placeholder`,
    /// `required` (false when absent), `min_length` and `max_length`; a radio
    /// group's `options` and `required`; a checkbox group's `min_values` and
    /// `max_values` beside those; a checkbox's `default`.
    var modalField: InteractionModal.Field? {
        switch type {
        case 1:
            return .row((components ?? []).compactMap(\.modalField))
        case 18:
            guard let inner = component?.first?.modalField else { return nil }
            return .label(text: label ?? "", description: description, field: inner)
        case 10:
            return content.map(InteractionModal.Field.text)
        case 4:
            guard let custom_id else { return nil }
            return .textInput(InteractionModal.TextInput(
                customID: custom_id,
                label: label,
                isParagraph: style == 2,
                value: value,
                placeholder: placeholder,
                isRequired: required ?? false,
                minLength: min_length,
                maxLength: max_length
            ))
        case 3:
            guard let custom_id else { return nil }
            return .select(SelectMenu(
                customID: custom_id,
                placeholder: placeholder,
                options: (options ?? []).compactMap(\.domain),
                minValues: min_values ?? 1,
                maxValues: max_values ?? 1
            ))
        case 21, 22:
            guard let custom_id else { return nil }
            let choice = InteractionModal.Choice(
                customID: custom_id,
                options: (options ?? []).compactMap(\.domain),
                minValues: min_values,
                maxValues: max_values,
                isRequired: required ?? false
            )
            return type == 21 ? .radioGroup(choice) : .checkboxGroup(choice)
        case 23:
            guard let custom_id else { return nil }
            return .checkbox(customID: custom_id, isDefault: self.default ?? false)
        case 5, 6, 7, 8:
            // Discord's modal defaults: one choice, required.
            guard let custom_id, let kind = InteractionModal.EntitySelect.Kind(rawValue: type ?? 0) else { return nil }
            let minimum = min_values ?? 1
            return .entitySelect(InteractionModal.EntitySelect(
                kind: kind,
                customID: custom_id,
                placeholder: placeholder,
                minValues: minimum,
                maxValues: max_values ?? 1,
                isRequired: required ?? (minimum > 0),
                defaultIDs: (default_values ?? []).map(\.id),
                channelTypes: channel_types ?? []
            ))
        case 19:
            guard let custom_id else { return nil }
            let minimum = min_values ?? 1
            return .fileUpload(InteractionModal.FileUpload(
                customID: custom_id,
                minValues: minimum,
                maxValues: max_values ?? 1,
                isRequired: required ?? (minimum > 0)
            ))
        case let type?:
            return .unsupported(type: type, customID: custom_id)
        case nil:
            return nil
        }
    }
}

/// `POST /interactions`, `type: 5` — a form sent back.
///
/// **Discord's client's body** (its modal chunk's submit, web
/// `d4c7976eccf337f1`): `application_id`, `channel_id`, `guild_id`,
/// `data: {id, custom_id, components}`, `session_id`, `nonce` — and each field
/// walked back to `{type, custom_id, value | values}`: a text input's `value`,
/// a select's or a checkbox group's `values`, a radio group's `value`, a
/// checkbox's `value` as a boolean, a label as `{type, component}`, text as
/// `{type}`. A field this client has no surface for goes back as Discord's
/// does for one left alone: its values `null`.
public struct ModalSubmission: Encodable, Sendable {
    var type = 5
    var application_id: String
    var channel_id: String
    /// Explicitly null outside a server, as `ComponentInteraction` sends it.
    var guild_id: String?
    var data: Payload
    var session_id: String
    var nonce: String
    /// The files a form's uploads sent ahead, by the ids their fields name.
    var attachments: [UploadedAttachment]?

    struct UploadedAttachment: Encodable, Sendable {
        var id: String
        var filename: String
        var uploaded_filename: String
    }

    struct Payload: Encodable, Sendable {
        var id: String
        var custom_id: String
        var components: [SubmittedField]
    }

    public init(
        modal: InteractionModal,
        answers: [String: InteractionModal.Answer],
        guildID: GuildID?,
        sessionID: String,
        nonce: String,
        uploads: [UploadSlot] = []
    ) {
        attachments = uploads.isEmpty ? nil : uploads.map {
            UploadedAttachment(id: $0.id, filename: $0.filename, uploaded_filename: $0.uploadedFilename)
        }
        application_id = modal.applicationID.description
        channel_id = modal.channelID.description
        guild_id = guildID?.description
        data = Payload(
            id: modal.id,
            custom_id: modal.customID,
            components: modal.fields.map { SubmittedField($0, answers: answers) }
        )
        session_id = sessionID
        self.nonce = nonce
    }

    enum CodingKeys: String, CodingKey {
        case type, application_id, channel_id, guild_id, data, session_id, nonce
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(application_id, forKey: .application_id)
        try container.encode(channel_id, forKey: .channel_id)
        try container.encode(guild_id, forKey: .guild_id)
        try container.encode(data, forKey: .data)
        try container.encode(session_id, forKey: .session_id)
        try container.encode(nonce, forKey: .nonce)
    }
}

/// One field going back. See `ModalSubmission`.
indirect enum SubmittedField: Encodable, Sendable {
    case row([SubmittedField])
    case label(SubmittedField)
    /// Just its type — text, or a field without an id.
    case bare(type: Int)
    case textInput(customID: String, value: String?)
    case values(type: Int, customID: String, values: [String]?)
    case radio(customID: String, value: String?)
    case checkbox(customID: String, value: Bool)

    init(_ field: InteractionModal.Field, answers: [String: InteractionModal.Answer]) {
        switch field {
        case .row(let children):
            self = .row(children.map { SubmittedField($0, answers: answers) })
        case .label(_, _, let inner):
            self = .label(SubmittedField(inner, answers: answers))
        case .text:
            self = .bare(type: 10)
        case .textInput(let input):
            guard case .text(let text) = answers[input.customID] else {
                self = .textInput(customID: input.customID, value: nil)
                return
            }
            self = .textInput(customID: input.customID, value: text)
        case .select(let menu):
            self = .values(type: menu.type, customID: menu.customID, values: InteractionModal.values(answers[menu.customID]))
        case .radioGroup(let choice):
            self = .radio(customID: choice.customID, value: InteractionModal.values(answers[choice.customID]).first)
        case .checkboxGroup(let choice):
            self = .values(type: 22, customID: choice.customID, values: InteractionModal.values(answers[choice.customID]))
        case .checkbox(let customID, let isDefault):
            if case .flag(let value) = answers[customID] {
                self = .checkbox(customID: customID, value: value)
            } else {
                self = .checkbox(customID: customID, value: isDefault)
            }
        case .entitySelect(let select):
            self = .values(
                type: select.kind.rawValue, customID: select.customID,
                values: InteractionModal.values(answers[select.customID])
            )
        case .fileUpload(let upload):
            // By then the files are uploaded and the answer is their ids —
            // `SessionController.submitInteractionModal` does it first.
            let ids = InteractionModal.values(answers[upload.customID])
            self = .values(type: 19, customID: upload.customID, values: ids.isEmpty ? nil : ids)
        case .unsupported(let type, let customID):
            self = customID.map { .values(type: type, customID: $0, values: nil) } ?? .bare(type: type)
        }
    }

    private enum Keys: String, CodingKey {
        case type, components, component, custom_id, value, values
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .row(let children):
            try container.encode(1, forKey: .type)
            try container.encode(children, forKey: .components)
        case .label(let inner):
            try container.encode(18, forKey: .type)
            try container.encode(inner, forKey: .component)
        case .bare(let type):
            try container.encode(type, forKey: .type)
        case .textInput(let customID, let value):
            try container.encode(4, forKey: .type)
            try container.encode(customID, forKey: .custom_id)
            try container.encode(value, forKey: .value)
        case .values(let type, let customID, let values):
            try container.encode(type, forKey: .type)
            try container.encode(customID, forKey: .custom_id)
            try container.encode(values, forKey: .values)
        case .radio(let customID, let value):
            try container.encode(21, forKey: .type)
            try container.encode(customID, forKey: .custom_id)
            try container.encode(value, forKey: .value)
        case .checkbox(let customID, let value):
            try container.encode(23, forKey: .type)
            try container.encode(customID, forKey: .custom_id)
            try container.encode(value, forKey: .value)
        }
    }
}

extension DiscordREST {
    /// Sends a form back. Answers `204`; what the application does with it
    /// arrives over the socket, as a press's answer does.
    public func submitModal(_ submission: ModalSubmission) async throws {
        _ = try await requestData(method: "POST", path: "/interactions", route: "interactions", body: submission)
    }
}
