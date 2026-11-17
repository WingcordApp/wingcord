import AVFoundation
import CoreMedia
import SwiftUI
import WingcordCore
import WingcordVoice

// MARK: - The tiles, and how they move
//
// Every tile carries a `matchedGeometryEffect` keyed on the person, in one
// namespace shared by the grid and the spotlight. That single fact is what makes
// the motion work: a tile does not *appear* in a new slot when somebody joins —
// it **travels** to it, and the tile that is promoted to the stage flies there
// from wherever it was standing.
//
// The arithmetic is `VoiceGridLayout`, which is a value with tests, because a
// grid that reshuffles is the most obvious defect a call surface can have and
// "does it reshuffle" is not a thing you can see reliably by looking.
struct VoiceTileGrid: View {
    var participants: [VoiceParticipant]
    var spotlightUserID: UserID?
    var effects: [UserID: String]
    var cameraSession: CaptureSessionHandle?
    var selfUserID: UserID?
    var attachVideo: (UserID, (@Sendable (CMSampleBuffer) -> Void)?) -> Void
    /// Opens or closes somebody's screen share. Nil where watching cannot work.
    var watch: ((UserID) -> Void)?
    var spotlight: (UserID?) -> Void
    /// The activity running in this call, if any: a Join tile in the grid, or,
    /// once the reader is in it, the call's stage (decision 3).
    var activity: CallActivityPresentation? = nil
    var joinActivity: (CallActivityPresentation) -> Void = { _ in }

    @Environment(\.motion) private var motion
    /// Read for Show Non-Video Participants and by the right-click, nothing
    /// else.
    @Environment(AppModel.self) private var model
    @Namespace private var tiles

    var body: some View {
        GeometryReader { proxy in
            content(in: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height)
                // **Declared here, not at the store write.** §3 forbids wrapping
                // a store assignment in `withAnimation`: that opens a global
                // transaction and every view that re-lays out while it runs
                // animates. The grid says how the grid moves.
                //
                // `reposition` is the class for larger travel that is not a
                // gesture, critically damped — a tile that has arrived
                // somewhere should not wobble about it.
                .animation(motion.reposition, value: shown.map(\.id))
                .animation(motion.reposition, value: spotlightUserID)
                .animation(motion.reposition, value: proxy.size)
        }
        // Each tile's colour is read out of its avatar once, and only for a
        // call that is on screen.
        .onChange(of: pendingGrounds, initial: true) { _, pictures in
            for picture in pictures { model.sessionController.derivePalette(at: picture) }
        }
    }

    /// The pictures whose colours the tiles drawn are still waiting for.
    private var pendingGrounds: [URL] {
        shown.compactMap { $0.ground == nil ? $0.groundArtwork : nil }
    }

    /// The menu a tile raises, from its ⋯ or a right-click: in a direct
    /// message's call the conversation's, about the person on the tile; in a
    /// server's the person menu — each with the call's items.
    private func openMenu(for userID: UserID, at rect: CGRect) {
        guard let callID = model.connectedVoiceChannelID else { return }
        if let guildID = model.channelIndex[callID]?.guildID {
            model.openUserMenu(for: userID, anchor: rect, inGuild: guildID, isFromCall: true)
        } else {
            model.openDirectMessageMenu(for: callID, anchor: rect, callUserID: userID)
        }
    }

    /// The tiles drawn: everybody, or — with Discord's Show Non-Video
    /// Participants off — the people with a picture, unless that is nobody.
    private var shown: [VoiceParticipant] {
        guard !model.showsNonVideoParticipants else { return participants }
        let withVideo = participants.filter(\.showsVideo)
        return withVideo.isEmpty ? participants : withVideo
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        if let activity, activity.isJoined {
            activityLayout(activity, in: size)
        } else if let spotlightUserID, let starring = shown.first(where: { $0.id == spotlightUserID }) {
            spotlightLayout(starring: starring, in: size)
        } else {
            grid(in: size)
        }
    }

    // MARK: The even grid

    private func grid(in size: CGSize) -> some View {
        // The activity's Join tile takes one more slot, after the people.
        let items = shown.map(CallGridItem.person) + (activity.map { [CallGridItem.activity($0)] } ?? [])
        let layout = VoiceGridLayout.solve(count: items.count, in: size)
        return VStack(spacing: VoiceGridLayout.spacing) {
            ForEach(layout.rowRanges(count: items.count), id: \.lowerBound) { range in
                HStack(spacing: VoiceGridLayout.spacing) {
                    ForEach(items[range]) { item in
                        switch item {
                        case .person(let participant):
                            tile(participant, isCompact: layout.tileSize.width < 220)
                                .frame(width: layout.tileSize.width, height: layout.tileSize.height)
                        case .activity(let activity):
                            CallActivityTile(activity: activity) { joinActivity(activity) }
                                .frame(width: layout.tileSize.width, height: layout.tileSize.height)
                                .matchedGeometryEffect(id: "activity", in: tiles)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The activity on the stage

    /// The activity the reader is in, big, with everybody in the strip under
    /// it: Discord's focused activity.
    private func activityLayout(_ activity: CallActivityPresentation, in size: CGSize) -> some View {
        let layout = VoiceSpotlightLayout.solve(others: shown.count, in: size)
        return VStack(spacing: VoiceSpotlightLayout.stripGap) {
            CallActivityStage(activity: activity)
                .frame(width: layout.stage.width, height: layout.stage.height)
                .matchedGeometryEffect(id: "activity", in: tiles)
            if !shown.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.base) {
                        ForEach(shown) { participant in
                            tile(participant, isCompact: true)
                                .frame(width: layout.chipSize.width, height: layout.chipSize.height)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollIndicators(.never)
                .frame(height: layout.strip.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: One person filling the stage

    private func spotlightLayout(starring: VoiceParticipant, in size: CGSize) -> some View {
        let others = shown.filter { $0.id != starring.id }
        let layout = VoiceSpotlightLayout.solve(others: others.count, in: size)
        return VStack(spacing: VoiceSpotlightLayout.stripGap) {
            tile(starring, isCompact: false)
                .frame(width: layout.stage.width, height: layout.stage.height)

            if !others.isEmpty {
                // Scrolls when there are more chips than fit. Everything is
                // still on screen at eight; past that the strip would shrink
                // every chip to nothing to keep them all visible, which is the
                // trade nobody wants.
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.base) {
                        ForEach(others) { participant in
                            tile(participant, isCompact: true)
                                .frame(
                                    width: layout.chipSize.width,
                                    height: layout.chipSize.height
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollIndicators(.never)
                .frame(height: layout.strip.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: One tile

    private func tile(_ participant: VoiceParticipant, isCompact: Bool) -> some View {
        VoiceTile(
            participant: participant,
            effectName: effects[participant.id],
            cameraSession: participant.id == selfUserID ? cameraSession : nil,
            attachVideo: attachVideo,
            reportVideoPixels: model.reportVideoPixels,
            watch: watch,
            openMenu: { openMenu(for: participant.id, at: $0) },
            isCompact: isCompact
        )
        // The whole of the travel. Keyed on the person, so a tile moving from
        // slot four to slot two — or from the strip to the stage — is one
        // continuous movement rather than one view leaving and another arriving.
        .matchedGeometryEffect(id: participant.id, in: tiles)
        // Spatial symmetry: a tile grows out of nothing at its own place and
        // shrinks back into it.
        //
        // **Without the blur, and that is not a taste decision.** `materialize`
        // normally scales and blurs together, and a blur forces an offscreen
        // pass — inside which this tile's `.ultraThinMaterial` ground has no
        // backdrop to sample and paints black, at the layer's own square bounds
        // rather than the rounded clip. That is a dark, hard-cornered rectangle
        // inset by the 0.90 scale, sitting inside the rounded tile: exactly
        // what a photograph of the running app showed. §4, and the rule that
        // anything rasterising glass destroys it.
        .transition(.materialize(from: .center, blurring: false))
        .onTapGesture(count: 2) {
            // Double-click to fill the stage, and again to let go of it. A
            // single click would fight the pointer's own hover, and a button
            // over a video tile is chrome nobody asked for.
            spotlight(spotlightUserID == participant.id ? nil : participant.id)
        }
        // **The person menu, as Discord's call tile raises it** — with the
        // call's own items, User Volume first. Double-click still fills the
        // stage.
        .onSecondaryClick { openMenu(for: participant.id, at: $0) }
    }
}
