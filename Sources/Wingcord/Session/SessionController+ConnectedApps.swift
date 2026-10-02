import AppKit
import Foundation
import WingcordCore
import WingcordNet

// MARK: - Connections and Authorized Apps
//
// `GET /users/@me/connections` and `GET /oauth2/tokens`. Both are asked for
// once when the pane opens — Discord's own client fetches both together
// regardless of which tab is showing, and a capture of the real settings
// window confirms it — and after that the pane's own actions keep the two
// tables in step without a refetch.

extension SessionController {

    // MARK: Loading

    /// `model.connections == nil` means "not asked yet"; `[]` means asked and
    /// empty, exactly like a guild surface — see `AppModel`.
    func loadConnections() {
        guard model.connections == nil, connectedAppsFetches.insert(.connections).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { connectedAppsFetches.remove(.connections) }
            do {
                model.connections = try await rest.connections()
            } catch {
                model.connections = []
                Self.trace("connections failed: \(Self.describe(error))")
            }
        }
    }

    /// The toolbar's Refresh — the only way to see a connection linked from
    /// the browser this session opened, since there is no callback to catch.
    func refreshConnectedApps() {
        model.connections = nil
        model.authorizedApps = nil
        loadConnections()
        loadAuthorizedApps()
    }

    func loadAuthorizedApps() {
        guard model.authorizedApps == nil, connectedAppsFetches.insert(.authorizedApps).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { connectedAppsFetches.remove(.authorizedApps) }
            do {
                model.authorizedApps = try await rest.authorizedApps()
            } catch {
                model.authorizedApps = []
                Self.trace("authorized apps failed: \(Self.describe(error))")
            }
        }
    }

    // MARK: Connections — mutating

    /// "Display on profile".
    ///
    /// **The switch moves first.** The route answers with the same connection
    /// it was sent, which replaces the optimistic write with the server's own
    /// — the same shape `setChannelFollowed` reads its answer back for, and
    /// for the same reason: a client that trusted its own guess would disagree
    /// with the account the moment a second client touched the same row.
    func setConnectionVisible(_ isVisible: Bool, _ connection: AccountConnection) {
        guard model.connectionMutationsInFlight.insert(connection.id).inserted else { return }
        let previous = connection
        replaceConnection(connection.id) { $0.isVisibleOnProfile = isVisible }
        Task { [weak self] in
            guard let self else { return }
            defer { model.connectionMutationsInFlight.remove(connection.id) }
            do {
                let updated = try await rest.setConnectionVisible(
                    isVisible, type: connection.type, id: connection.id
                )
                replaceConnection(connection.id) { $0 = updated }
            } catch {
                replaceConnection(connection.id) { $0 = previous }
                Self.trace("set visible \(connection.id) failed: \(Self.describe(error))")
            }
        }
    }

    /// "Display \(platform) as your status".
    func setConnectionShowsActivity(_ shows: Bool, _ connection: AccountConnection) {
        guard model.connectionMutationsInFlight.insert(connection.id).inserted else { return }
        let previous = connection
        replaceConnection(connection.id) { $0.showsActivity = shows }
        Task { [weak self] in
            guard let self else { return }
            defer { model.connectionMutationsInFlight.remove(connection.id) }
            do {
                let updated = try await rest.setConnectionShowsActivity(
                    shows, type: connection.type, id: connection.id
                )
                replaceConnection(connection.id) { $0 = updated }
                // "Display Spotify as your status" decides the Listening
                // activity, which is on the presence now or must leave it.
                if connection.type == "spotify" { publishPresence() }
            } catch {
                replaceConnection(connection.id) { $0 = previous }
                Self.trace("set shows activity \(connection.id) failed: \(Self.describe(error))")
            }
        }
    }

    /// Unlinks a connection. `DELETE` answers `204`, so there is nothing to
    /// read back — the row is simply gone, or it is restored at the index it
    /// came from.
    func removeConnection(_ connection: AccountConnection) {
        guard model.connectionMutationsInFlight.insert(connection.id).inserted,
              let index = model.connections?.firstIndex(of: connection)
        else { return }
        model.connections?.remove(at: index)
        Task { [weak self] in
            guard let self else { return }
            defer { model.connectionMutationsInFlight.remove(connection.id) }
            do {
                try await rest.removeConnection(type: connection.type, id: connection.id)
                if connection.type == "spotify" { stopFollowingSpotify(connection.id) }
            } catch {
                let insertAt = min(index, model.connections?.count ?? 0)
                model.connections?.insert(connection, at: insertAt)
                Self.trace("remove connection \(connection.id) failed: \(Self.describe(error))")
            }
        }
    }

    /// Opens the system browser to link a new connection. There is no
    /// callback this app can catch — Discord's redirect lands on a
    /// `discord.com` page, not a URL scheme this app registers — so the pane
    /// simply asks again when the reader comes back; see the toolbar's Refresh.
    func beginLinkingConnection(type: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await rest.connectionAuthorizeURL(type: type)
                NSWorkspace.shared.open(url)
            } catch {
                Self.trace("connection authorize \(type) failed: \(Self.describe(error))")
            }
        }
    }

    private func replaceConnection(_ id: String, mutate: (inout AccountConnection) -> Void) {
        guard let index = model.connections?.firstIndex(where: { $0.id == id }) else { return }
        mutate(&model.connections![index])
    }

    // MARK: Authorized apps — mutating

    /// Deauthorizes an app. Same shape as `removeConnection`: the write moves
    /// first, and a failure puts the row back where it was.
    func deauthorizeApp(_ app: AuthorizedApp) {
        guard model.authorizedAppRevocationsInFlight.insert(app.id).inserted,
              let index = model.authorizedApps?.firstIndex(of: app)
        else { return }
        model.authorizedApps?.remove(at: index)
        Task { [weak self] in
            guard let self else { return }
            defer { model.authorizedAppRevocationsInFlight.remove(app.id) }
            do {
                try await rest.deauthorizeApp(app.id)
            } catch {
                let insertAt = min(index, model.authorizedApps?.count ?? 0)
                model.authorizedApps?.insert(app, at: insertAt)
                Self.trace("deauthorize \(app.id) failed: \(Self.describe(error))")
            }
        }
    }

    // MARK: Domain connections
    //
    // The one platform with no browser redirect. `submitDomainConnection`
    // starts it; `retryDomainVerification` is what "Verify" sends after the
    // reader has published the DNS record or the well-known file — inferred
    // to be the identical call, since the reference client's own retry
    // answered the exact same "not yet" shape a fresh submission does, and
    // this route has never been observed to want anything else in its body.

    /// Opens the sheet on its empty first page. Plain state, no network yet —
    /// there is nothing to submit until a domain is typed.
    func beginDomainConnection() {
        model.domainConnectionSheet = DomainConnectionSheet(domain: "", phase: .enteringDomain)
    }

    func submitDomainConnection(_ domain: String) {
        let trimmed = domain.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.domainConnectionSheet = DomainConnectionSheet(domain: trimmed, phase: .submitting)
        attemptDomainConnection(trimmed)
    }

    /// **Keeps the proof on screen while it checks.** The reader already
    /// published a DNS record or a file for it; a retry that blanked the
    /// instructions to show a spinner would hide the one thing they might
    /// still need to re-copy if they mistyped it.
    func retryDomainVerification() {
        guard let sheet = model.domainConnectionSheet,
              case .pending(let proof, _) = sheet.phase
        else { return }
        model.domainConnectionSheet?.phase = .verifying(proof: proof)
        attemptDomainConnection(sheet.domain)
    }

    func dismissDomainConnectionSheet() {
        model.domainConnectionSheet = nil
    }

    private func attemptDomainConnection(_ domain: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                switch try await rest.startDomainConnection(domain) {
                case .pending(let proof):
                    guard model.domainConnectionSheet?.domain == domain else { return }
                    model.domainConnectionSheet?.phase = .pending(proof: proof, lastError: nil)
                case .verified:
                    guard model.domainConnectionSheet?.domain == domain else { return }
                    model.domainConnectionSheet = nil
                    refreshConnectedApps()
                }
            } catch {
                guard let sheet = model.domainConnectionSheet, sheet.domain == domain else { return }
                let message = Self.describe(error)
                // A failed first submission has no proof to keep; a failed
                // retry keeps whatever it was already showing.
                if case .verifying(let proof) = sheet.phase {
                    model.domainConnectionSheet?.phase = .pending(proof: proof, lastError: message)
                } else {
                    model.domainConnectionSheet?.phase = .failed(message)
                }
                Self.trace("domain connection \(domain) failed: \(message)")
            }
        }
    }
}

/// The "Connect your Domain" sheet's own state — typed in, submitted, and
/// either handed a token to go publish or told it already worked.
struct DomainConnectionSheet: Identifiable, Sendable {
    let id = UUID()
    var domain: String
    var phase: Phase

    enum Phase: Sendable, Equatable {
        case enteringDomain
        /// The first submission, before any proof has ever come back.
        case submitting
        /// `proof` is what to publish — as a DNS TXT record at
        /// `_discord.<domain>`, or as the contents of a file at
        /// `<domain>/.well-known/discord`. `lastError` is set only after a
        /// Verify has been tried and failed; a fresh proof carries none.
        case pending(proof: String, lastError: String?)
        /// A retry in flight. Carries the same proof `.pending` showed, so
        /// the instructions never disappear while it checks.
        case verifying(proof: String)
        /// The *first* submission failed outright — no proof was ever
        /// issued, so there is nothing to keep showing.
        case failed(String)
    }
}

/// Which of the two connected-apps lists is in flight, as one set. No pane
/// reads this directly — `model.connections == nil` already says "loading"
/// exactly like a guild surface's absent entry does — so unlike
/// `GuildSurfaceFetch` this stays a plain de-dup guard on the controller.
enum ConnectedAppsFetch: Hashable, Sendable {
    case connections
    case authorizedApps
}
