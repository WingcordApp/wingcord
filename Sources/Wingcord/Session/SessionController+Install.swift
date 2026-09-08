import Foundation
import WingcordCore
import WingcordNet

// MARK: - Adding an application, and its store
//
// Two surfaces reached from an app's own page. Both are captured — `owo 2.har`
// and `owo store.har`, 2026-09-03 — and neither is a route this client had.

extension SessionController {

    // MARK: Add App

    /// Opens the sheet for one integration type.
    ///
    /// **Fetched per open, not cached.** `authorized` is the whole reason the
    /// sheet exists in two states, and a cached answer would offer to add an app
    /// the reader added a minute ago from somewhere else.
    func loadApplicationInstall(_ id: ApplicationID, integrationType: IntegrationType) async {
        model.applicationInstall = nil
        model.applicationInstallFailure = nil
        do {
            model.applicationInstall = try await rest.applicationInstall(
                id,
                integrationType: integrationType
            )
        } catch {
            model.applicationInstallFailure = Self.reason(for: error, verb: "open this app")
        }
    }

    /// Adds it.
    ///
    /// **This grants something, so it reports both ways.** Every other fetch
    /// here can fail into a blank surface; this one changes the reader's account
    /// and has to say whether it did.
    func installApplication(
        _ install: ApplicationInstall,
        into guildID: GuildID?,
        from channelID: ChannelID?
    ) async -> Bool {
        let channel = channelID.flatMap { model.channelIndex[$0] }
        do {
            try await rest.installApplication(
                install.applicationID,
                integrationType: install.integrationType,
                parameters: install.parameters,
                guildID: guildID,
                from: channelID,
                // **Nil, not a guessed `1`, where there is no channel.** The
                // route takes the sentinel there and the two cases are on the
                // wire — see `DiscordREST.installApplication`.
                channelKind: channelID == nil ? nil : (channel?.kind.rawValue ?? 1),
                currentGuildID: channel?.guildID
            )
        } catch {
            model.applicationInstallFailure = Self.reason(
                for: error,
                verb: "add \(install.name)"
            )
            return false
        }
        // Its commands are now in a scope this session has already cached, and
        // the cached copy does not have them. Dropping the account index is what
        // makes the new app's commands appear after a `/` rather than after a
        // relaunch.
        model.commandIndexes[.account] = nil
        if let guildID { model.commandIndexes[.guild(guildID)] = nil }
        model.commandRevision &+= 1
        return true
    }

    /// Whether an application has a storefront, from its own public record.
    ///
    /// Fetched with the page rather than discovered by trying: 1,359 bytes, and
    /// it is what decides whether the page offers an Open Store row at all.
    func loadApplicationStorefrontFlag(_ id: ApplicationID) async {
        guard model.applicationStorefronts[id] == nil else { return }
        model.applicationStorefronts[id] =
            (try? await rest.applicationPublicInfo(id).hasStorefront) ?? false
        model.storeRevision &+= 1
    }

    // MARK: The store

    /// One application's storefront.
    ///
    /// Guarded per application: the page is re-evaluated on every scroll, and
    /// the catalogue changes about as often as the developer ships one.
    func loadApplicationStore(_ id: ApplicationID) async {
        guard model.applicationStores[id] == nil else { return }
        do {
            // The reader's own region, from the system rather than from a
            // route: the capture's client sends `country_code=MD` because that
            // is where the account is, and `Locale` already knows.
            let store = try await rest.applicationStore(
                id,
                countryCode: Locale.current.region?.identifier
            )
            model.applicationStores[id] = store
        } catch {
            // **Stored as empty rather than left absent.** Absent means "not
            // asked", so a page whose store 404s would ask again on every
            // evaluation and be refused identically every time.
            model.applicationStores[id] = ApplicationStore(applicationID: id)
            Self.trace("store: \(id) unavailable — \(Self.describe(error))")
        }
        model.storeRevision &+= 1
    }
}
