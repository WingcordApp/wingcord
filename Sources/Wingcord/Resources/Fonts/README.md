# Display name style faces

The eleven faces Discord offers for a styled display name. `font_id: 1` is
"no custom font" and resolves to the app's own face — **gg sans is Discord's
licensed font and is deliberately not here.**

Each file is the *exact weight* Discord declares in its own `@font-face`, read
off `document.fonts` in a live client. They are scattered across 400-700 and
cannot be guessed; five of a first attempt were wrong. Look faces up by
PostScript name, never by family — six of these carry the weight in their family
string, and Medieval's family is `Néo-castel :-)`.

| id | Discord's label | file | weight | PostScript name |
|----|-----------------|------|--------|-----------------|
|  3 | Sakura      | CherryBombOne-Regular | 400 | `CherryBombOne-Regular` |
|  4 | Jellybean   | Chicle-Regular        | 400 | `Chicle-Regular` |
|  6 | Modern      | MuseoModerno-Medium   | 500 | `MuseoModerno-Medium` |
|  7 | Medieval    | Neo-castel            | 400 | `Neo-castel-:-` |
|  8 | 8Bit        | PixelifySans-Regular  | 400 | `PixelifySans-Regular` |
| 10 | Vampyre     | Sinistre-Regular      | 400 | `Sinistre-Regular` |
| 12 | Tempo       | ZillaSlab-SemiBold    | 600 | `ZillaSlab-SemiBold` |
| 13 | Monkey Bars | PlaypenSans-Bold      | 700 | `PlaypenSans-Bold` |
| 14 | Mainframe   | Orbitron-Bold         | 700 | `Orbitron-Bold` |
| 15 | Headbang    | NewRocker-Regular     | 400 | `NewRocker-Regular` |
| 16 | Journal     | Kalam-Bold            | 700 | `Kalam-Bold` |

## Licensing — one file needs checking before release

Ten of the eleven carry an SIL Open Font License string in their `name` table
(id 13). **The OFL requires its full text to accompany redistribution**, so an
`OFL.txt` should be added beside these before the app ships. That has not been
done here because the licence files were not part of what was downloaded.

**`Neo-castel.ttf` carries no licence string at all** and is the one face that is
not a Google Font. Its terms are unverified. It is also the odd one out
technically — 1024 units/em against everyone else's 1000, 212 glyphs, and a
PostScript name with a colon in it.

## Not subsetted, deliberately

Display names carry arbitrary Unicode and font fallback happens per *glyph*, not
per name — so a trimmed face renders most of a name styled and one character in
the fallback, mid-word. Chicle, Neo-castel and Orbitron are Latin-only as
shipped; only Pixelify, Playpen Sans and Sinistre carry Cyrillic. That is
Discord's behaviour too, and the renderer matches it.

Playpen Sans (729 KB) and Kalam (450 KB) are 54% of the 2.2 MB total.
