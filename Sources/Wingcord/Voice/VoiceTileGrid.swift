import AVFoundation
import CoreMedia
import SwiftUI
import WingcordCore

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
    var cameraSession: AVCaptureSession?
    var selfUserID: UserID?
    var attachVideo: (UserID, (@Sendable (CMSampleBuffer) -> Void)?) -> Void
    /// Opens or closes somebody's screen share. Nil where watching cannot work.
    var watch: ((UserID) -> Void)?
    var spotlight: (UserID?) -> Void

    @Environment(\.motion) private var motion
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
                .animation(motion.reposition, value: participants.map(\.id))
                .animation(motion.reposition, value: spotlightUserID)
                .animation(motion.reposition, value: proxy.size)
        }
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        if let spotlightUserID, let starring = participants.first(where: { $0.id == spotlightUserID }) {
            spotlightLayout(starring: starring, in: size)
        } else {
            grid(in: size)
        }
    }

    // MARK: The even grid

    private func grid(in size: CGSize) -> some View {
        let layout = VoiceGridLayout.solve(count: participants.count, in: size)
        return VStack(spacing: VoiceGridLayout.spacing) {
            ForEach(layout.rowRanges(count: participants.count), id: \.lowerBound) { range in
                HStack(spacing: VoiceGridLayout.spacing) {
                    ForEach(participants[range]) { participant in
                        tile(participant, isCompact: layout.tileSize.width < 220)
                            .frame(width: layout.tileSize.width, height: layout.tileSize.height)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: One person filling the stage

    private func spotlightLayout(starring: VoiceParticipant, in size: CGSize) -> some View {
        let others = participants.filter { $0.id != starring.id }
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
            watch: watch,
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
        .contextMenu {
            Button(spotlightUserID == participant.id ? "Leave Full Screen" : "Focus") {
                spotlight(spotlightUserID == participant.id ? nil : participant.id)
            }
        }
    }
}
