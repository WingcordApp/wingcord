import Foundation

/// The languages Discord's own pickers offer, in Discord's own order.
///
/// **One list, two surfaces.** A community server declares its `preferred_locale`
/// from this list, and discovery's search filters on that same value with
/// `language_code` — so a filter offering anything else would be offering to
/// search for a value no server can hold. Server settings picks from it; the
/// discovery bar's language menu picks from it.
///
/// **The titles are Discord's, not the system's.** `Locale.localizedString`
/// answers "Portuguese (Brazil)" where Discord writes "Portuguese, Brazilian",
/// and the two pickers have to read the same or the same server is filed under
/// two names.
enum GuildLocale {
    struct Entry: Identifiable, Hashable, Sendable {
        var id: String { code }
        var code: String
        var title: String
    }

    static let all: [Entry] = [
        Entry(code: "en-US", title: "English, US"),
        Entry(code: "en-GB", title: "English, UK"),
        Entry(code: "bg", title: "Bulgarian"),
        Entry(code: "zh-CN", title: "Chinese, China"),
        Entry(code: "zh-TW", title: "Chinese, Taiwan"),
        Entry(code: "hr", title: "Croatian"),
        Entry(code: "cs", title: "Czech"),
        Entry(code: "da", title: "Danish"),
        Entry(code: "nl", title: "Dutch"),
        Entry(code: "fi", title: "Finnish"),
        Entry(code: "fr", title: "French"),
        Entry(code: "de", title: "German"),
        Entry(code: "el", title: "Greek"),
        Entry(code: "hi", title: "Hindi"),
        Entry(code: "hu", title: "Hungarian"),
        Entry(code: "id", title: "Indonesian"),
        Entry(code: "it", title: "Italian"),
        Entry(code: "ja", title: "Japanese"),
        Entry(code: "ko", title: "Korean"),
        Entry(code: "lt", title: "Lithuanian"),
        Entry(code: "no", title: "Norwegian"),
        Entry(code: "pl", title: "Polish"),
        Entry(code: "pt-BR", title: "Portuguese, Brazilian"),
        Entry(code: "ro", title: "Romanian"),
        Entry(code: "ru", title: "Russian"),
        Entry(code: "es-ES", title: "Spanish"),
        Entry(code: "es-419", title: "Spanish, LATAM"),
        Entry(code: "sv-SE", title: "Swedish"),
        Entry(code: "th", title: "Thai"),
        Entry(code: "tr", title: "Turkish"),
        Entry(code: "uk", title: "Ukrainian"),
        Entry(code: "vi", title: "Vietnamese"),
    ]

    /// One language by its tag, for a menu that has to name what is selected.
    ///
    /// A dictionary rather than a scan: the bar reads it on every evaluation
    /// and the list is thirty-two long.
    static func named(_ code: String) -> String? { byCode[code] }

    private static let byCode: [String: String] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.code, $0.title) }
    )
}
