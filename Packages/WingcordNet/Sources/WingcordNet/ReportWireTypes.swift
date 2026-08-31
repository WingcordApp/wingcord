import Foundation
import WingcordCore

/// `GET /reporting/menu/{message|user}`.
///
/// Two shapes in this payload cannot be expressed with synthesised `Codable`,
/// and both are decoded by hand below:
///
///  - **`children` is a heterogeneous array of pairs** — `["Spam", 98]` — a
///    label and a node id in one JSON array.
///  - **`elements[].data` is polymorphic.** It is `null` for most elements, an
///    object for an external link, and an array of `[value, label]` pairs for a
///    checkbox. Which one it is depends on the sibling `type` field, so it is
///    decoded per element rather than as a type of its own.
struct ReportMenuDTO: Decodable, Sendable {
    var name: String?
    var variant: String?
    var version: String?
    var root_node_id: Int?
    var nodes: [String: NodeDTO]?

    struct NodeDTO: Decodable, Sendable {
        var id: Int
        var header: String?
        var subheader: String?
        var info: String?
        var button: ButtonDTO?
        var elements: [ElementDTO]?
        var report_type: String?
        var children: [ChildDTO]?
        var is_auto_submit: Bool?
    }

    struct ButtonDTO: Decodable, Sendable {
        var type: String?
        var target: Int?
    }

    /// One `["label", id]` pair.
    struct ChildDTO: Decodable, Sendable {
        var label: String
        var nodeID: Int

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            label = try container.decode(String.self)
            nodeID = try container.decode(Int.self)
        }
    }

    struct ElementDTO: Decodable, Sendable {
        var name: String?
        var type: String?
        var data: ElementData?

        private enum Keys: String, CodingKey { case name, type, data }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            // `data` means whatever `type` says it means, and the two live side
            // by side — so it is read against the type rather than sniffed.
            switch type {
            case "checkbox", "radio":
                let pairs = try container.decodeIfPresent([OptionDTO].self, forKey: .data)
                data = pairs.map { .options($0.map { ReportOption(value: $0.value, label: $0.label) }) }
            case "external_link":
                data = try container.decodeIfPresent(LinkDTO.self, forKey: .data).map { .link($0) }
            default:
                data = nil
            }
        }
    }

    enum ElementData: Sendable {
        case options([ReportOption])
        case link(LinkDTO)
    }

    /// One `["face_pic", "Face pic"]` pair.
    struct OptionDTO: Decodable, Sendable {
        var value: String
        var label: String

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            value = try container.decode(String.self)
            label = try container.decode(String.self)
        }
    }

    struct LinkDTO: Decodable, Sendable {
        var link_text: String?
        var url: String?
    }

    var domain: ReportMenu {
        var resolved: [Int: ReportNode] = [:]
        resolved.reserveCapacity(nodes?.count ?? 0)
        for node in nodes?.values ?? [:].values {
            resolved[node.id] = ReportNode(
                id: node.id,
                header: node.header ?? "",
                subheader: node.subheader,
                info: node.info,
                button: Self.button(node.button),
                elements: (node.elements ?? []).map(Self.element),
                reportType: node.report_type,
                children: (node.children ?? []).map {
                    ReportChoice(label: $0.label, nodeID: $0.nodeID)
                },
                isAutoSubmit: node.is_auto_submit ?? false
            )
        }
        return ReportMenu(
            name: name ?? "message",
            variant: variant ?? "",
            version: version ?? "1.0",
            rootNodeID: root_node_id ?? 0,
            nodes: resolved
        )
    }

    private static func button(_ dto: ButtonDTO?) -> ReportButton? {
        guard let dto, let type = dto.type else { return nil }
        switch type {
        case "submit": return .submit
        case "cancel": return .cancel
        case "done": return .done
        case "next": return dto.target.map(ReportButton.next)
        // An unrecognised button type is treated as an end rather than as a
        // step to nowhere: a flow that cannot advance must still close.
        default: return .done
        }
    }

    private static func element(_ dto: ElementDTO) -> ReportElement {
        switch dto.type {
        case "message_preview", "app_preview", "user_preview":
            return .subjectPreview
        case "breadcrumbs":
            return .breadcrumbs
        case "checkbox", "radio":
            guard let name = dto.name, case .options(let options)? = dto.data, !options.isEmpty
            else { return .decoration }
            return .checkbox(name: name, options: options)
        case "external_link":
            guard case .link(let link)? = dto.data,
                  let text = link.link_text,
                  let raw = link.url,
                  let url = URL(string: raw),
                  url.scheme == "https"
            else { return .decoration }
            return .externalLink(text: text, url: url)
        case "block_users":
            return .followUp(.block)
        case "ignore_users":
            return .followUp(.ignore)
        case "delete_message":
            return .followUp(.deleteMessage)
        // `share_with_parents`, `mute_users`, `settings_upsells`, `success`,
        // `fail` and `skip` are all surfaces this client has no route for. They
        // draw nothing rather than becoming controls that answer nothing.
        default:
            return .decoration
        }
    }
}

/// `POST /reporting/{message|user}`.
///
/// **The breadcrumbs are the report.** The taxonomy lives entirely in the tree
/// that was fetched, so what is posted is the path through it plus whatever the
/// elements on that path collected — which is why the version and variant go
/// back untouched: a path only means something against the tree it came from.
struct ReportSubmissionDTO: Encodable, Sendable {
    var version: String
    var variant: String
    var language: String
    var breadcrumbs: [Int]
    var elements: [String: [String]]
    var name: String
    var channel_id: String?
    var message_id: String?
    var guild_id: String?
    var user_id: String?
}
