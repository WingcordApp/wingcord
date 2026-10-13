import Foundation

/// What a file is, by the icon Discord draws for it — `453771`'s `T`: the first
/// rule that matches, a MIME rule against the content type and a name rule
/// against the lowercased filename; "unknown" when none does.
///
/// **Discord's rules, quirks included.** `.ae` is not anchored, so any name
/// with ".ae" in it is an After Effects file; a MIME rule never matches a file
/// that came without a content type.
public enum AttachmentFileKind: String, CaseIterable, Sendable {
    case photoshop
    case webcode
    case image
    case video
    case acrobat
    case ae
    case sketch
    case ai
    case archive
    case code
    case document
    case spreadsheet
    case audio
    case unknown

    public init(filename: String, contentType: String?) {
        let name = filename.lowercased()
        let type = contentType?.lowercased()
        for rule in Self.rules {
            switch rule.test {
            case .type(let pattern):
                if let type, type.firstMatch(of: pattern) != nil {
                    self = rule.kind
                    return
                }
            case .name(let pattern):
                if !name.isEmpty, name.firstMatch(of: pattern) != nil {
                    self = rule.kind
                    return
                }
            }
        }
        self = .unknown
    }

    /// The icon's file name. Discord ships no `photoshop` icon — its map has
    /// `ps`, and asking it for `photoshop` throws — so a Photoshop file draws
    /// the `ps` one, which is the icon it meant.
    public var iconName: String { "icon-file-\(self == .photoshop ? "ps" : rawValue)" }

    private enum Test {
        case type(Regex<Substring>)
        case name(Regex<Substring>)
    }

    nonisolated(unsafe) private static let rules: [(test: Test, kind: AttachmentFileKind)] = [
        (.type(/^image\/vnd.adobe.photoshop/), .photoshop),
        (.type(/^image\/svg\+xml/), .webcode),
        (.type(/^image\//), .image),
        (.type(/^video\//), .video),
        (.name(/\.pdf$/), .acrobat),
        (.name(/\.ae/), .ae),
        (.name(/\.sketch$/), .sketch),
        (.name(/\.ai$/), .ai),
        (.name(/\.(?:rar|zip|7z|tar|tar\.gz)$/), .archive),
        (.name(/\.(?:c\+\+|cpp|cc|c|h|hpp|mm|m|json|js|ts|rb|rake|py|asm|fs|pyc|dtd|cgi|bat|rss|java|graphml|idb|lua|o|gml|prl|sls|conf|cmake|make|sln|vbe|cxx|wbf|vbs|r|wml|php|bash|applescript|fcgi|yaml|ex|exs|sh|ml|actionscript)$/), .code),
        (.name(/\.(?:txt|rtf|doc|docx|md|pages|ppt|pptx|pptm|key|log)$/), .document),
        (.name(/\.(?:xls|xlsx|numbers|csv)$/), .spreadsheet),
        (.name(/\.(?:html|xhtml|htm|xml|xsd|css|styl)$/), .webcode),
        (.name(/\.(?:mp3|ogg|opus|wav|aiff|flac)$/), .audio),
    ]
}
