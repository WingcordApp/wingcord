import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// A profile opened again draws what it has while it is asked again — the
/// skeleton is for a first load only — and is not asked again within a
/// minute (Alex, 2026-10-26: "profile loading — one thing we should really
/// focus on").
@MainActor
@Suite("Profile revalidation")
struct ProfileRevalidationTests {

    private func model() throws -> (AppModel, UserID) {
        let model = AppModel()
        DemoFixtures.populate(model)
        let me = try #require(model.currentUserID)
        let other = try #require(model.users.keys.sorted { $0.rawValue < $1.rawValue }.first { $0 != me })
        return (model, other)
    }

    @Test("A first load shows the skeleton; a reload keeps the card")
    func skeletonOnlyForTheFirstLoad() throws {
        let (model, other) = try model()
        let request = ProfileRequest(userID: other, showsMainProfile: true, anchor: .zero)
        model.profilesLoading.insert(other)
        #expect(model.profilePresentation(for: request)?.isLoading == true)
        // It has arrived before: the card keeps it while the fetch runs.
        model.profileFetchedAt[ProfileFetchKey(userID: other, guildID: nil)] = .now
        #expect(model.profilePresentation(for: request)?.isLoading == false)
    }

    @Test("Opened again within a minute, a profile is not asked for again")
    func freshProfilesAreNotRefetched() throws {
        let (model, other) = try model()
        model.profileFetchedAt[ProfileFetchKey(userID: other, guildID: nil)] = .now
        model.sessionController.loadProfile(of: other, inGuild: nil)
        #expect(!model.profilesLoading.contains(other), "a fresh profile was fetched again")
        // (A stale one is asked for — the route's old behaviour, not tested
        // here because it would reach Discord from a test.)
    }
}
