import Foundation
import WingcordCore
import WingcordNet

extension SessionController {
    /// The card's pictures, as its application knows them — Discord's
    /// `fetchAssetIds`: a link through the application's external assets, a
    /// key from the application's own list. Each is asked once a session;
    /// nothing is asked without a valid Application ID, which pictures need.
    func resolveCustomPresenceAssets(of presence: CustomPresence) async {
        guard presence.carriesArt, let id = UInt64(presence.applicationID) else { return }
        let application = ApplicationID(rawValue: id)
        let prefix = presence.applicationID + " "
        let wanted = [
            presence.problem(.largeImage) == nil ? presence.largeArt.image : "",
            presence.problem(.smallImage) == nil ? presence.smallArt.image : "",
        ]
        let missing = Set(wanted.filter { !$0.isEmpty && model.customPresenceAssets[prefix + $0] == nil })
        guard !missing.isEmpty else { return }
        let links = missing.filter { $0.hasPrefix("http:") || $0.hasPrefix("https:") }
        let keys = missing.subtracting(links)
        if !links.isEmpty {
            do {
                for (link, asset) in try await rest.externalAssetIDs(application: application, urls: Array(links)) {
                    model.customPresenceAssets[prefix + link] = asset
                }
            } catch {
                Self.trace("presence picture links refused: \(Self.describe(error))")
            }
        }
        if !keys.isEmpty {
            do {
                let named = try await rest.applicationAssetIDs(application: application)
                for key in keys { if let asset = named[key] { model.customPresenceAssets[prefix + key] = asset } }
            } catch {
                Self.trace("presence picture keys refused: \(Self.describe(error))")
            }
        }
    }
}
