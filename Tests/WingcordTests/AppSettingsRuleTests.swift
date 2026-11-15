import Foundation
import Testing

/// The rule in `AppSettingsIsolation.swift`, checked: no test file changes
/// `AppSettings.shared` except through `withAppSettings`, whose body gets the
/// settings as a parameter. It reads the test sources, so a test written any
/// other way fails here, named by file and line.
@Suite("App settings rule")
struct AppSettingsRuleTests {
    @Test("No test changes AppSettings.shared except through withAppSettings")
    func settingsChangeOnlyThroughTheHelper() throws {
        // The ways to reach the shared settings for writing without the helper.
        let patterns = try [
            ("assigns to it", #"AppSettings\.shared\.[A-Za-z_]\w*(\.[A-Za-z_]\w*)*\s*([-+*/%|&^]|<<|>>)?=(?!=)"#),
            ("mutates one of its properties",
             #"AppSettings\.shared\.[A-Za-z_]\w*\.(insert|remove|removeAll|removeValue|append|toggle|merge|formUnion|subtract|updateValue)\("#),
            ("binds it to a name", #"=\s*AppSettings\.shared\b(?!\.)"#),
            ("passes it along", #"[(,:]\s*AppSettings\.shared\s*[),]"#),
        ].map { ($0.0, try NSRegularExpression(pattern: $0.1)) }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let exempt: Set<String> = ["AppSettingsIsolation.swift", "AppSettingsRuleTests.swift"]
        let files = try FileManager.default.subpathsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".swift") && !exempt.contains(($0 as NSString).lastPathComponent) }
        #expect(files.count > 100, "the test sources were found")

        var found: [String] = []
        for file in files.sorted() {
            let text = try String(contentsOf: folder.appending(path: file), encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                let range = NSRange(code.startIndex..., in: code)
                for (what, pattern) in patterns where pattern.firstMatch(in: code, range: range) != nil {
                    found.append("\(file):\(index + 1) \(what)")
                }
            }
        }
        #expect(found.isEmpty, """
            Change AppSettings.shared inside withAppSettings (AppSettingsIsolation.swift): \
            \(found.joined(separator: "; "))
            """)
    }
}
