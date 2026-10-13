import Foundation
import WingcordCore

/// An app as a local RPC socket knows it: who connected, under what name an
/// activity without one is shown, and which web origins may speak for it.
public struct RPCApplication: Hashable, Sendable {
    public var id: ApplicationID
    public var name: String
    /// The pages allowed to open a WebSocket for this app — `rpc_origins`.
    public var rpcOrigins: [String]

    public init(id: ApplicationID, name: String, rpcOrigins: [String] = []) {
        self.id = id
        self.name = name
        self.rpcOrigins = rpcOrigins
    }
}

extension DiscordREST {

    /// The app a socket's handshake names — Discord's handshake asks this
    /// route (`90924`'s `H`) and closes the socket with "Invalid Client ID"
    /// when it fails: `GET /oauth2/applications/{id}/rpc`.
    public func rpcApplication(_ id: ApplicationID) async throws -> RPCApplication {
        struct ApplicationDTO: Decodable {
            var id: WireID?
            var name: String?
            var rpc_origins: [String]?
        }
        let dto = try await get(
            "/oauth2/applications/\(id.rawValue)/rpc",
            route: "oauth2/applications/{id}/rpc",
            as: ApplicationDTO.self
        )
        guard let name = dto.name, !name.isEmpty else { throw Failure.notFound }
        return RPCApplication(
            id: dto.id?.value.map(ApplicationID.init(rawValue:)) ?? id,
            name: name,
            rpcOrigins: dto.rpc_origins ?? []
        )
    }
}
