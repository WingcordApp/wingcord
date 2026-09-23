# Super reaction effects

Discord's eighteen desktop super reaction effects — Lottie JSON, LZFSE-compressed
(1.65 MB of JSON is 125 KB here, and decompressing one costs well under a
millisecond). Each file is named for its slot in `SuperReactionEffect.names`, and
**the order of that table is the answer**: the effect a reaction plays is chosen
by hashing the channel, the message and the emoji's name into it.

The artwork is Discord's. It is bundled for the same reason the voice sounds are:
the client Discord ships loads it from its own web bundle, where the chunk names
are content hashes that change on redeploy — there is no stable URL to fetch it
from at run time.

## Where each one came from

Module `299072` of Discord's web client loads them through a table of webpack
chunks; each chunk is `JSON.parse('<the whole animation>')`.

| slot | file | Discord's name | chunk |
|---:|---|---|---|
|  0 | BlastOff   | `BurstReaction_BlastOff_v04`          | 277339 |
|  1 | Arcade     | `BurstReaction_Arcade_v02_Lottie`     | 517087 |
|  2 | BlackHoles | `BurstReaction_BlackHoles_v02_Lottie` | 4289   |
|  3 | Crystal    | `BurstReaction_Crystal_v04`           | 366414 |
|  4 | Fireworks  | `BurstReaction_Fireworks_v03`         | 331165 |
|  5 | Fusion     | `BurstReaction_Fusion_v03`            | 158541 |
|  6 | Pop        | `BurstReaction_Pop_v04`               | 910169 |
|  7 | PowerUp    | `BurstReaction_PowerUp_v05`           | 276601 |
|  8 | StarBlast  | `BurstReaction_StarBlast_v03`         | 623997 |
|  9 | Bubbles    | `BurstReaction_03_Bubbles_v03`        | 91770  |
| 10 | Slime      | `BurstReaction_03_Slime_v07`          | 109302 |
| 11 | Portal     | `BurstReaction_03_Portal_v04`         | 196515 |
| 12 | Anime      | `BurstReaction_Anime_v03_Lottie`      | 674149 |
| 13 | Puzzle     | `BurstReaction_Puzzle_v03_Lottie`     | 484163 |
| 14 | Spotlight  | `BurstReaction_Spotlight_v03_Lottie`  | 252029 |
| 15 | Tube       | `BurstReaction_Tube_v02_Lottie`       | 667133 |
| 16 | UFO        | `BurstReaction_UFO_v02_Lottie`        | 684765 |
| 17 | Whirlwind  | `BurstReaction_Whirlwind_v02_Lottie`  | 235583 |

Every one is a 300 × 300 composition at 60 fps, 2.7 to 4.7 seconds long, with
exactly one image asset — `image_0`, a 128-unit square — which is where the
emoji goes. Every colour meant to follow the chip is authored as pure red or pure
blue (`[1,0,0,` and `[0,0,1,`), which `SuperReactionEffect.recolored` swaps for
the chip's own pair before the animation is parsed.

## Regenerating

Resolve each chunk id in `web.js`'s chunk map (the object literal ending
`})[e]+".js"`), fetch `https://discord.com/assets/<hash>.js`, take the string
inside `JSON.parse('…')` and undo its single-quote escaping, then compress with
`NSData.compressed(using: .lzfse)`. `SuperReactionEffectTests` decodes all
eighteen, so a file that does not round-trip fails the suite.
