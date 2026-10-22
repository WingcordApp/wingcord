import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `shared_client_theme`, as a message carries it and a send writes it.
struct SharedClientThemeWireTests {

    @Test("A message's shared theme is read; one Discord would not keep is dropped")
    func decodes() throws {
        let json = #"""
        {"id":"1","channel_id":"2","author":{"id":"3","username":"alex"},"content":"","type":0,
         "shared_client_theme":{"colors":["5865F2","#EB459E"],"gradient_angle":90,"base_mix":74,"base_theme":1}}
        """#
        let message = try JSONDecoder().decode(MessageDTO.self, from: Data(json.utf8)).domain
        let theme = try #require(message.sharedTheme)
        #expect(theme.colors == [0x58_65_F2, 0xEB_45_9E])
        #expect(theme.gradientAngle == 90)
        #expect(theme.baseMix == 74)
        #expect(!theme.isLight)
        #expect(!message.isEmpty, "a theme with no words is still a body")

        let broken = #"""
        {"id":"1","channel_id":"2","author":{"id":"3","username":"alex"},"content":"hi","type":0,
         "shared_client_theme":{"colors":"nope","base_theme":9}}
        """#
        let survived = try JSONDecoder().decode(MessageDTO.self, from: Data(broken.utf8)).domain
        #expect(survived.content == "hi", "a shape this cannot read costs the card, never the message")
        #expect(survived.sharedTheme == nil)
    }

    @Test("A send writes the share modal's shape: hex without #, the numbers")
    func encodes() throws {
        let theme = SharedClientTheme(colors: [0x58_65_F2], gradientAngle: 180, baseMix: 60, baseTheme: 2)
        let data = try JSONEncoder().encode(SharedClientThemeDTO(theme))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["colors"] as? [String] == ["5865F2"])
        #expect(object["gradient_angle"] as? Double == 180)
        #expect(object["base_mix"] as? Double == 60)
        #expect(object["base_theme"] as? Int == 2)
    }
}
