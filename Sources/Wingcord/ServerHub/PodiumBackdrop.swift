import SwiftUI

/// The star field behind the podium: Discord's own still and loop, 685 points
/// wide and centred (`.background_i8iX4X`), with the drawn field standing in
/// until — or unless — they arrive.
///
/// **The still alone under Reduce Motion**, as Discord does (`t_`).
struct PodiumBackdrop: View {
    @Environment(\.motion) private var motion
    @State private var loop: URL?

    var body: some View {
        ZStack {
            RemoteImage(url: DiscordPodiumArt.backdropStill, side: PodiumPlace.backdropWidth, bucket: .artwork) {
                LeaderboardPodiumBackdrop()
            }
            .scaledToFill()
            if let loop {
                LoopingVideo(url: loop, isPlaying: !motion.reduceMotion)
                    .opacity(motion.reduceMotion ? 0 : 1)
            }
        }
        .frame(width: PodiumPlace.backdropWidth, height: PodiumPlace.podiumHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            loop = await PodiumBackdropLoop.localURL()
        }
    }
}
