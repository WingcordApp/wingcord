import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The `application` a bot's profile carries — the fields Discord's profile
/// store keeps — and that nothing in it can take the profile down.
@Suite("Profile application decode")
struct ProfileApplicationDecodeTests {

    private func decode(_ application: String) throws -> User {
        let json = """
        {
          "user": { "id": "4", "username": "helper", "discriminator": "0", "bot": true },
          "user_profile": { "bio": "I help" },
          "application": \(application)
        }
        """
        return try JSONDecoder().decode(UserProfileDTO.self, from: Data(json.utf8)).domain
    }

    @Test("Intents, the install routes, the store and the two links")
    func fields() throws {
        let user = try decode("""
        {
          "id": "4", "flags": \(1 << 18 | 1 << 13), "storefront_available": true,
          "integration_types_config": { "0": { "oauth2_install_params": { "scopes": ["bot"], "permissions": "8" } }, "1": {} },
          "terms_of_service_url": "https://helper.test/tos",
          "privacy_policy_url": "https://helper.test/privacy"
        }
        """)
        let application = try #require(user.decoration?.application)
        #expect(application.id == ApplicationID(rawValue: 4))
        #expect(application.dataAccess == [.messageContent, .presence])
        #expect(application.isInstallable)
        #expect(application.hasStorefront)
        #expect(application.termsOfServiceURL?.absoluteString == "https://helper.test/tos")
        #expect(user.decoration?.bio == "I help")
    }

    @Test("An app with nowhere to install offers no Add App")
    func notInstallable() throws {
        let application = try #require(try decode(#"{ "id": "4", "flags": 0, "integration_types_config": { "1": {} } }"#)
            .decoration?.application)
        #expect(!application.isInstallable)
        #expect(application.dataAccess.isEmpty)
        let custom = try #require(try decode(#"{ "id": "4", "custom_install_url": "https://helper.test/add" }"#)
            .decoration?.application)
        #expect(custom.isInstallable)
    }

    @Test("A malformed application costs only itself")
    func malformed() throws {
        let user = try decode(#"{ "id": "4", "flags": "lots", "storefront_available": "yes" }"#)
        #expect(user.decoration?.bio == "I help")
        #expect(user.decoration?.application?.flags == 0)
        #expect(try decode("[1, 2]").decoration?.bio == "I help")
    }
}
