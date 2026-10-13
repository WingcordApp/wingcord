import Foundation
import WingcordCore

extension DiscordREST {
    /// The `mp:` ids a presence sends for pictures given as links — Discord's
    /// `fetchAssetIds` for a link: `POST /applications/{id}/external-assets
    /// {urls}`, answered with each link's `external_asset_path`.
    ///
    /// - Returns: each link it answered for, by the link, as `mp:{path}`.
    public func externalAssetIDs(application: ApplicationID, urls: [String]) async throws -> [String: String] {
        guard !urls.isEmpty else { return [:] }
        struct Body: Encodable { var urls: [String] }
        struct Asset: Decodable {
            var url: String
            var external_asset_path: String
        }
        let assets = try await request(
            method: "POST",
            path: "/applications/\(application.rawValue)/external-assets",
            route: "applications/{id}/external-assets",
            body: Body(urls: urls),
            as: [Asset].self
        )
        return Dictionary(assets.map { ($0.url, "mp:" + $0.external_asset_path) }, uniquingKeysWith: { first, _ in first })
    }

    /// The application's own pictures by name, for a presence that names one —
    /// Discord's `fetchAssetIds` for a key: `GET /oauth2/applications/{id}/assets`.
    ///
    /// - Returns: each asset's id, by its name.
    public func applicationAssetIDs(application: ApplicationID) async throws -> [String: String] {
        struct Asset: Decodable {
            var id: String
            var name: String
        }
        let assets = try await get(
            "/oauth2/applications/\(application.rawValue)/assets",
            route: "oauth2/applications/{id}/assets",
            as: [Asset].self
        )
        return Dictionary(assets.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
    }
}
