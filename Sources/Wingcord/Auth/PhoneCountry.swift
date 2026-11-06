import Foundation

/// One row of the country picker beside a phone number: a country and one of
/// its dialling codes. A handful of countries have several, and Discord's
/// picker lists each as its own row.
///
/// **Discord's own list** (`96337`, build 663810), names and codes as it ships
/// them; the name on screen is the Mac's own for the region where it has one.
nonisolated struct PhoneCode: Hashable, Identifiable, Sendable {
    var alpha2: String
    /// Discord's English name, the fallback and what a search also matches.
    var name: String
    /// As Discord writes it: "+44", or "+1 684" for American Samoa.
    var code: String

    var id: String { "\(alpha2) \(code)" }

    /// What goes before the number: the code's first part, as Discord's field
    /// takes it (`code.split(" ")[0]`) — "+1" for American Samoa too.
    var prefix: String { String(code.split(separator: " ").first ?? Substring(code)) }

    var localizedName: String {
        Locale.current.localizedString(forRegionCode: alpha2) ?? name
    }

    /// The Mac's region, the way Discord defaults to the country it locates
    /// the reader in. The United States where the region isn't one of them.
    static func preferred(for locale: Locale = .current) -> PhoneCode {
        let region = locale.region?.identifier
        return all.first { $0.alpha2 == region } ?? all.first { $0.alpha2 == "US" }!
    }

    /// Matches a search the way Discord's picker does: the name, in English or
    /// the Mac's language, or the code.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return name.localizedStandardContains(needle)
            || localizedName.localizedStandardContains(needle)
            || code.contains(needle)
            || alpha2.localizedCaseInsensitiveCompare(needle) == .orderedSame
    }

    static let all: [PhoneCode] = countries.flatMap { country in
        country.codes.map { PhoneCode(alpha2: country.alpha2, name: country.name, code: $0) }
    }

    private struct Country {
        var alpha2: String
        var name: String
        var codes: [String]
        init(_ alpha2: String, _ name: String, _ codes: [String]) {
            self.alpha2 = alpha2
            self.name = name
            self.codes = codes
        }
    }

    private static let countries: [Country] = [
        Country("AF", "Afghanistan", ["+93"]),
        Country("AX", "Aland Islands", ["+358"]),
        Country("AL", "Albania", ["+355"]),
        Country("DZ", "Algeria", ["+213"]),
        Country("AS", "American Samoa", ["+1 684"]),
        Country("AD", "Andorra", ["+376"]),
        Country("AO", "Angola", ["+244"]),
        Country("AI", "Anguilla", ["+1 264"]),
        Country("AQ", "Antarctica", ["+672"]),
        Country("AG", "Antigua and Barbuda", ["+1 268"]),
        Country("AR", "Argentina", ["+54"]),
        Country("AM", "Armenia", ["+374"]),
        Country("AW", "Aruba", ["+297"]),
        Country("AC", "Ascension", ["+247"]),
        Country("AU", "Australia", ["+61"]),
        Country("AT", "Austria", ["+43"]),
        Country("AZ", "Azerbaijan", ["+994"]),
        Country("BS", "Bahamas", ["+1 242"]),
        Country("BH", "Bahrain", ["+973"]),
        Country("BD", "Bangladesh", ["+880"]),
        Country("BB", "Barbados", ["+1 246"]),
        Country("BY", "Belarus", ["+375"]),
        Country("BE", "Belgium", ["+32"]),
        Country("BZ", "Belize", ["+501"]),
        Country("BJ", "Benin", ["+229"]),
        Country("BM", "Bermuda", ["+1 441"]),
        Country("BT", "Bhutan", ["+975"]),
        Country("BO", "Bolivia, Plurinational State of", ["+591"]),
        Country("BQ", "Bonaire, Sint Eustatius and Saba", ["+599"]),
        Country("BA", "Bosnia and Herzegovina", ["+387"]),
        Country("BW", "Botswana", ["+267"]),
        Country("BV", "Bouvet Island", ["+55"]),
        Country("BR", "Brazil", ["+55"]),
        Country("IO", "British Indian Ocean Territory", ["+246"]),
        Country("BN", "Brunei Darussalam", ["+673"]),
        Country("BG", "Bulgaria", ["+359"]),
        Country("BF", "Burkina Faso", ["+226"]),
        Country("BI", "Burundi", ["+257"]),
        Country("KH", "Cambodia", ["+855"]),
        Country("CM", "Cameroon", ["+237"]),
        Country("CA", "Canada", ["+1"]),
        Country("CV", "Cape Verde", ["+238"]),
        Country("KY", "Cayman Islands", ["+1 345"]),
        Country("CF", "Central African Republic", ["+236"]),
        Country("TD", "Chad", ["+235"]),
        Country("CL", "Chile", ["+56"]),
        Country("CN", "China", ["+86"]),
        Country("CX", "Christmas Island", ["+61"]),
        Country("CC", "Cocos (Keeling) Islands", ["+61"]),
        Country("CO", "Colombia", ["+57"]),
        Country("KM", "Comoros", ["+269"]),
        Country("CG", "Congo", ["+242"]),
        Country("CD", "Congo, The Democratic Republic of the", ["+243"]),
        Country("CK", "Cook Islands", ["+682"]),
        Country("CR", "Costa Rica", ["+506"]),
        Country("CI", "Cote d'Ivoire", ["+225"]),
        Country("HR", "Croatia", ["+385"]),
        Country("CU", "Cuba", ["+53"]),
        Country("CW", "Curacao", ["+599"]),
        Country("CY", "Cyprus", ["+357"]),
        Country("CZ", "Czech Republic", ["+420"]),
        Country("DK", "Denmark", ["+45"]),
        Country("DG", "Diego Garcia", ["+246"]),
        Country("DJ", "Djibouti", ["+253"]),
        Country("DM", "Dominica", ["+1 767"]),
        Country("DO", "Dominican Republic", ["+1 809", "+1 829", "+1 849"]),
        Country("EC", "Ecuador", ["+593"]),
        Country("EG", "Egypt", ["+20"]),
        Country("SV", "El Salvador", ["+503"]),
        Country("GQ", "Equatorial Guinea", ["+240"]),
        Country("ER", "Eritrea", ["+291"]),
        Country("EE", "Estonia", ["+372"]),
        Country("ET", "Ethiopia", ["+251"]),
        Country("FK", "Falkland Islands (Malvinas)", ["+500"]),
        Country("FO", "Faroe Islands", ["+298"]),
        Country("FJ", "Fiji", ["+679"]),
        Country("FI", "Finland", ["+358"]),
        Country("FR", "France", ["+33"]),
        Country("GF", "French Guiana", ["+594"]),
        Country("PF", "French Polynesia", ["+689"]),
        Country("TF", "French Southern Territories", ["+262"]),
        Country("GA", "Gabon", ["+241"]),
        Country("GM", "Gambia", ["+220"]),
        Country("GE", "Georgia", ["+995"]),
        Country("DE", "Germany", ["+49"]),
        Country("GH", "Ghana", ["+233"]),
        Country("GI", "Gibraltar", ["+350"]),
        Country("GR", "Greece", ["+30"]),
        Country("GL", "Greenland", ["+299"]),
        Country("GD", "Grenada", ["+1 473"]),
        Country("GP", "Guadeloupe", ["+590"]),
        Country("GU", "Guam", ["+1 671"]),
        Country("GT", "Guatemala", ["+502"]),
        Country("GG", "Guernsey", ["+44"]),
        Country("GN", "Guinea", ["+224"]),
        Country("GW", "Guinea-Bissau", ["+245"]),
        Country("GY", "Guyana", ["+592"]),
        Country("HT", "Haiti", ["+509"]),
        Country("HM", "Heard Island and McDonald Islands", ["+672"]),
        Country("VA", "Holy See (Vatican City State)", ["+39"]),
        Country("HN", "Honduras", ["+504"]),
        Country("HK", "Hong Kong", ["+852"]),
        Country("HU", "Hungary", ["+36"]),
        Country("IS", "Iceland", ["+354"]),
        Country("IN", "India", ["+91"]),
        Country("ID", "Indonesia", ["+62"]),
        Country("IR", "Iran, Islamic Republic of", ["+98"]),
        Country("IQ", "Iraq", ["+964"]),
        Country("IE", "Ireland", ["+353"]),
        Country("IM", "Isle of Man", ["+44"]),
        Country("IL", "Israel", ["+972"]),
        Country("IT", "Italy", ["+39"]),
        Country("JM", "Jamaica", ["+1 876"]),
        Country("JP", "Japan", ["+81"]),
        Country("JE", "Jersey", ["+44"]),
        Country("JO", "Jordan", ["+962"]),
        Country("KZ", "Kazakhstan", ["+7"]),
        Country("KE", "Kenya", ["+254"]),
        Country("KI", "Kiribati", ["+686"]),
        Country("XK", "Kosovo", ["+383"]),
        Country("KP", "Korea, Democratic People's Republic of", ["+850"]),
        Country("KR", "Korea, Republic of", ["+82"]),
        Country("KW", "Kuwait", ["+965"]),
        Country("KG", "Kyrgyzstan", ["+996"]),
        Country("LA", "Lao People's Democratic Republic", ["+856"]),
        Country("LV", "Latvia", ["+371"]),
        Country("LB", "Lebanon", ["+961"]),
        Country("LS", "Lesotho", ["+266"]),
        Country("LR", "Liberia", ["+231"]),
        Country("LY", "Libya", ["+218"]),
        Country("LI", "Liechtenstein", ["+423"]),
        Country("LT", "Lithuania", ["+370"]),
        Country("LU", "Luxembourg", ["+352"]),
        Country("MO", "Macao", ["+853"]),
        Country("MK", "Macedonia, Republic of", ["+389"]),
        Country("MG", "Madagascar", ["+261"]),
        Country("MW", "Malawi", ["+265"]),
        Country("MY", "Malaysia", ["+60"]),
        Country("MV", "Maldives", ["+960"]),
        Country("ML", "Mali", ["+223"]),
        Country("MT", "Malta", ["+356"]),
        Country("MH", "Marshall Islands", ["+692"]),
        Country("MQ", "Martinique", ["+596"]),
        Country("MR", "Mauritania", ["+222"]),
        Country("MU", "Mauritius", ["+230"]),
        Country("YT", "Mayotte", ["+262"]),
        Country("MX", "Mexico", ["+52"]),
        Country("FM", "Micronesia, Federated States of", ["+691"]),
        Country("MI", "Midway Island", ["+1 808"]),
        Country("MD", "Moldova, Republic of", ["+373"]),
        Country("MC", "Monaco", ["+377"]),
        Country("MN", "Mongolia", ["+976"]),
        Country("ME", "Montenegro", ["+382"]),
        Country("MS", "Montserrat", ["+1664"]),
        Country("MA", "Morocco", ["+212"]),
        Country("MZ", "Mozambique", ["+258"]),
        Country("MM", "Myanmar", ["+95"]),
        Country("NA", "Namibia", ["+264"]),
        Country("NR", "Nauru", ["+674"]),
        Country("NP", "Nepal", ["+977"]),
        Country("NL", "Netherlands", ["+31"]),
        Country("AN", "Netherlands Antilles", ["+599"]),
        Country("NC", "New Caledonia", ["+687"]),
        Country("NZ", "New Zealand", ["+64"]),
        Country("NI", "Nicaragua", ["+505"]),
        Country("NE", "Niger", ["+227"]),
        Country("NG", "Nigeria", ["+234"]),
        Country("NU", "Niue", ["+683"]),
        Country("NF", "Norfolk Island", ["+672"]),
        Country("MP", "Northern Mariana Islands", ["+1 670"]),
        Country("NO", "Norway", ["+47"]),
        Country("OM", "Oman", ["+968"]),
        Country("PK", "Pakistan", ["+92"]),
        Country("PW", "Palau", ["+680"]),
        Country("PS", "Palestine, State of", ["+970"]),
        Country("PA", "Panama", ["+507"]),
        Country("PG", "Papua New Guinea", ["+675"]),
        Country("PY", "Paraguay", ["+595"]),
        Country("PE", "Peru", ["+51"]),
        Country("PH", "Philippines", ["+63"]),
        Country("PN", "Pitcairn", ["+64"]),
        Country("PL", "Poland", ["+48"]),
        Country("PT", "Portugal", ["+351"]),
        Country("PR", "Puerto Rico", ["+1 787"]),
        Country("QA", "Qatar", ["+974"]),
        Country("RE", "Reunion", ["+262"]),
        Country("RO", "Romania", ["+40"]),
        Country("RU", "Russian Federation", ["+7"]),
        Country("RW", "Rwanda", ["+250"]),
        Country("BL", "Saint Barthxe9lemy", ["+590"]),
        Country("SH", "Saint Helena, Ascension and Tristan da Cunha", ["+290"]),
        Country("KN", "Saint Kitts and Nevis", ["+1 869"]),
        Country("LC", "Saint Lucia", ["+1 758"]),
        Country("MF", "Saint Martin (French part)", ["+590"]),
        Country("PM", "Saint Pierre and Miquelon", ["+508"]),
        Country("VC", "Saint Vincent and the Grenadines", ["+1 784"]),
        Country("WS", "Samoa", ["+685"]),
        Country("SM", "San Marino", ["+378"]),
        Country("ST", "Sao Tome and Principe", ["+239"]),
        Country("SA", "Saudi Arabia", ["+966"]),
        Country("SN", "Senegal", ["+221"]),
        Country("RS", "Serbia", ["+381"]),
        Country("SC", "Seychelles", ["+248"]),
        Country("SL", "Sierra Leone", ["+232"]),
        Country("SG", "Singapore", ["+65"]),
        Country("SX", "Sint Maarten (Dutch part)", ["+1 721"]),
        Country("SK", "Slovakia", ["+421"]),
        Country("SI", "Slovenia", ["+386"]),
        Country("SB", "Solomon Islands", ["+677"]),
        Country("SO", "Somalia", ["+252"]),
        Country("ZA", "South Africa", ["+27"]),
        Country("GS", "South Georgia and the South Sandwich Islands", ["+500"]),
        Country("SS", "South Sudan", ["+211"]),
        Country("ES", "Spain", ["+34"]),
        Country("LK", "Sri Lanka", ["+94"]),
        Country("SD", "Sudan", ["+249"]),
        Country("SR", "Suriname", ["+597"]),
        Country("SJ", "Svalbard and Jan Mayen", ["+47"]),
        Country("SZ", "Swaziland", ["+268"]),
        Country("SE", "Sweden", ["+46"]),
        Country("CH", "Switzerland", ["+41"]),
        Country("SY", "Syrian Arab Republic", ["+963"]),
        Country("TW", "Taiwan", ["+886"]),
        Country("TJ", "Tajikistan", ["+992"]),
        Country("TZ", "Tanzania, United Republic of", ["+255"]),
        Country("TH", "Thailand", ["+66"]),
        Country("TL", "Timor-Leste", ["+670"]),
        Country("TG", "Togo", ["+228"]),
        Country("TK", "Tokelau", ["+690"]),
        Country("TO", "Tonga", ["+676"]),
        Country("TT", "Trinidad and Tobago", ["+1 868"]),
        Country("TN", "Tunisia", ["+216"]),
        Country("TR", "Turkey", ["+90"]),
        Country("TM", "Turkmenistan", ["+993"]),
        Country("TC", "Turks and Caicos Islands", ["+1 649"]),
        Country("TV", "Tuvalu", ["+688"]),
        Country("UG", "Uganda", ["+256"]),
        Country("UA", "Ukraine", ["+380"]),
        Country("AE", "United Arab Emirates", ["+971"]),
        Country("GB", "United Kingdom", ["+44"]),
        Country("US", "United States", ["+1"]),
        Country("UM", "United States Minor Outlying Islands", ["+1"]),
        Country("UY", "Uruguay", ["+598"]),
        Country("UZ", "Uzbekistan", ["+998"]),
        Country("VU", "Vanuatu", ["+678"]),
        Country("VE", "Venezuela, Bolivarian Republic of", ["+58"]),
        Country("VN", "Vietnam", ["+84"]),
        Country("VG", "Virgin Islands, British", ["+1 284"]),
        Country("VI", "Virgin Islands, U.S.", ["+1 340"]),
        Country("WF", "Wallis and Futuna", ["+681"]),
        Country("EH", "Western Sahara", ["+212"]),
        Country("YE", "Yemen", ["+967"]),
        Country("ZM", "Zambia", ["+260"]),
        Country("ZW", "Zimbabwe", ["+263"]),
    ]
}

/// Whether a login is a phone number.
nonisolated enum LoginKind {
    /// **Discord's rule** (`628387.Vl`): three or more characters, all digits,
    /// spaces, dashes or parentheses, and not starting with `+` — somebody who
    /// types the `+` has given the code themselves, and the pill steps aside.
    static func isPhone(_ text: String) -> Bool {
        text.count >= 3
            && !text.hasPrefix("+")
            && text.allSatisfy { ("0"..."9").contains($0) || $0 == "-" || $0 == "(" || $0 == ")" || $0 == " " }
    }

    /// What `POST /auth/login` is sent: the number as typed, after the code, the
    /// way Discord's field joins them (`loginPrefix + login`); an email trimmed.
    static func wireLogin(_ text: String, code: PhoneCode) -> String {
        isPhone(text) ? code.prefix + text : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
