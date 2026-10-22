import Foundation
import WingcordCore

extension SharedClientTheme {

    /// The reader's own blend as Discord's custom theme — what Plumage's Share
    /// sends (docs/CLIPS-PRESENCE.md, D25).
    ///
    /// **Its colours are the ones that land where the sharer's are.** Discord
    /// reads a custom theme through a veil — at a `base_mix` of 100, black at
    /// 58 % over the chat — so each stop goes out as its own page colour with
    /// that veil taken back off, and the page somebody previews it on, here or
    /// in Discord, is the page the sharer was looking at. The mix is 100 for
    /// the same reason: the colour of a blend is the whole of it, and the
    /// reader's vividness is already in the stops.
    ///
    /// A blend is always the dark room, so the share is too.
    init(sharing seed: ThemeSeed) {
        self.init(colors: [], gradientAngle: seed.angle, baseMix: 100, baseTheme: 1)
        let veil = ServerTheme(shared: self).pageVeil
        colors = seed.anchors.indices.map { index in
            Self.unveiled(seed.field(at: seed.position(ofAnchor: index)).packedRGB(), veil: veil)
        }
    }

    /// The colour that, with `veil` of black laid over it, is `shown` — each
    /// channel divided back up, held at white.
    static func unveiled(_ shown: UInt32, veil: Double) -> UInt32 {
        let keep = max(0.01, 1 - veil)
        func channel(_ shift: UInt32) -> UInt32 {
            let value = Double((shown >> shift) & 0xFF) / keep
            return UInt32(min(255, value.rounded())) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}
