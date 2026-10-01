import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `/games/autocomplete`, read off `game autocomplete.har` verbatim.
struct GameAutocompleteDecodeTests {

    @Test("Both icon shapes come through: a hash on the CDN, and a whole address")
    func iconShapes() throws {
        let captured = #"""
        [{"id":"1383506371810920543","name":"G-Force","icon":{"type":"hash","value":"ef8a67fe8e15973ddd20d6343b40e9b9"},"platform_availability":["console","desktop"]},
         {"id":"1554205410935521880","name":"G-Switch","icon":{"type":"url","value":"https://images-ext-1.discordapp.net/external/bbRIJD6SukYygSsmZxb6eic11d_sEZa8wrtt72hSfyQ/https/is1-ssl.mzstatic.com/image/thumb/Purple/v4/ea/c8/75/eac8751f-f69d-b7bb-1724-2edc75f9b39e/mzl.engtxgzp.png/150x150bb.jpg"},"platform_availability":["mobile"]},
         {"id":"1442729006420863621","name":"G - Darius"}]
        """#
        let games = try JSONDecoder().decode([GameAutocompleteDTO].self, from: Data(captured.utf8)).compactMap(\.domain)
        #expect(games.count == 3)
        #expect(games[0].iconHash == "ef8a67fe8e15973ddd20d6343b40e9b9")
        #expect(games[0].iconURL?.absoluteString.contains("/app-icons/1383506371810920543/") == true)
        #expect(games[1].iconHash == nil)
        #expect(games[1].iconURL?.host == "images-ext-1.discordapp.net")
        #expect(games[2].iconURL == nil)
    }
}
