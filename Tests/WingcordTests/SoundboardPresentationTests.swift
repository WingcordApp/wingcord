import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// Discord's soundboard order (`useSoundGrid`): Favorites, Frequently Used,
/// the call's own server, then Discord Sounds before the other servers — or
/// after them, with Nitro.
@MainActor
@Suite("Soundboard order")
struct SoundboardPresentationTests {
    private let home = GuildID(rawValue: 1)
    private let other = GuildID(rawValue: 2)
    private let room = ChannelID(rawValue: 100)
    private let reader = UserID(rawValue: 7)

    private func model(nitro: Bool) -> AppModel {
        let model = AppModel()
        model.currentUserID = reader
        model.guilds[home] = Guild(id: home, name: "Home", ownerID: reader)
        model.guilds[other] = Guild(id: other, name: "Other", ownerID: UserID(rawValue: 8))
        model.channelIndex.replaceChannels(
            [Channel(id: room, kind: .voice, guildID: home, name: "General")], inGuild: home
        )
        model.connectedVoiceChannelID = room
        if nitro { model.entitlements = AccountEntitlements(premiumTier: .nitro) }
        model.defaultSoundboardSounds = [SoundboardSound(id: "1", name: "quack")]
        model.guildSoundboardSounds[home] = [SoundboardSound(id: "10", name: "home", guildID: home)]
        model.guildSoundboardSounds[other] = [SoundboardSound(id: "20", name: "away", guildID: other)]
        model.soundboardFavorites = SoundboardFavorites(soundIDs: [20], orderedSoundIDs: [20])
        model.soundboardFrequentSoundIDs = ["20", "1"]
        return model
    }

    @Test("Without Nitro the other servers come last, locked")
    func withoutNitro() {
        let sections = model(nitro: false).soundboardPresentation.sections
        #expect(sections.map(\.id) == ["favorites", "frequently-used", "1", "default", "2"])
        #expect(sections.map(\.isLocked) == [false, false, false, false, true])
        // A favourite is not frequently used as well — Discord filters them.
        #expect(sections[1].sounds.map(\.id) == ["1"])
        // Another server's favourite plays only with Nitro, and says so in
        // Discord's words.
        #expect(sections[0].sounds.first?.isLocked == true)
        #expect(sections[0].sounds.first?.refusal == "Subscribe to Nitro to send sounds across servers.")
    }

    @Test("With Nitro, Discord Sounds goes last and nothing is locked")
    func withNitro() {
        let sections = model(nitro: true).soundboardPresentation.sections
        #expect(sections.map(\.id) == ["favorites", "frequently-used", "1", "2", "default"])
        let lockedSection = sections.contains(where: \.isLocked)
        let lockedSound = sections.flatMap(\.sounds).contains(where: \.isLocked)
        #expect(!lockedSection && !lockedSound)
    }

    /// The owner may add and manage: the server's section ends in Add Sound
    /// while a slot is free, and the volume menu leads to its settings.
    @Test("The call's server offers Add Sound and Server Settings to someone who manages it")
    func manager() {
        let presentation = model(nitro: false).soundboardPresentation
        #expect(presentation.sections[2].addSound?.canAdd == true)
        #expect(presentation.managedGuildID == home)
    }
}
