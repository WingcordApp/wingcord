import Foundation

/// Discord's podium star field, kept on disk after its first download.
///
/// **A local file, because AVFoundation keeps no cache of its own**: played
/// from its address, the four-second loop would be fetched again on every
/// visit to a hub. It is 250 KB, HEVC with an alpha channel, so it floats over
/// the card like Discord's.
enum PodiumBackdropLoop {
    /// The loop's file, downloading it first if this Mac has never seen it;
    /// nil when it can't be had, and the still or the drawn field stands in.
    static func localURL() async -> URL? {
        guard let remote = DiscordPodiumArt.backdropLoop,
              let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(path: "Wingcord/ServerHub", directoryHint: .isDirectory)
        else { return nil }
        let file = folder.appending(path: "podium-\(remote.lastPathComponent)")
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return file }
        do {
            let (download, response) = try await URLSession.shared.download(from: remote)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: download, to: file)
            return file
        } catch {
            return nil
        }
    }
}
