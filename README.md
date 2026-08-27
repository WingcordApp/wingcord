# Wingcord

A native macOS Discord client. macOS 27, Swift 6.4, SwiftUI with Liquid Glass —
and two drawn AppKit canvases where composing views would cost too much.

Built from zero. It shares no code with any previous client; it shares a *design
system* with Wingcord for iOS and a set of hard-won invariants with its
predecessor, both of which are written down in `docs/`.

---

## Build and run

```sh
./scripts/build-app.sh            # release, the default
./scripts/build-app.sh debug      # only for stepping through something
open build/Wingcord.app
```

Release is the default deliberately. A debug build is not evidence of anything:
SwiftUI's own machinery and every generic in the app are unoptimised there, so a
debug profile measures the compiler's output rather than the app's design.

### Tests

```sh
swift test --package-path Packages/WingcordCore   # domain, parser, permissions
swift test                                        # layout, painting, viewport
```

### Launch flags

| Flag | What it does |
| --- | --- |
| `--demo` | Fixture servers, channels, members and a 220-message transcript. Nothing else reaches it — there is no fallback from a failed sign-in into fixtures. |

---

## Shape

```
Packages/WingcordCore   domain values, markdown, permissions, timeline reducer
Packages/WingcordNet    REST, the Gateway socket, rate limiting, wire types
Sources/Wingcord        the app: design system, store, chrome, canvases
```

The two library targets are **not** main-actor isolated. The app target is
(`defaultIsolation(MainActor.self)`), so every escape from the main actor is an
explicit, greppable `nonisolated` — and decoding a READY payload, laying out a
transcript and decoding an image all happen off it by construction rather than by
remembering.

| Layer | What it owns |
| --- | --- |
| `AppModel` | Flat tables keyed by id, navigation, and memoized presentation projections. Never touches the network. |
| `SessionController` | The only thing that talks to the wire. Applies events to the store in one main-actor hop each. |
| `PermissionGate` | What the reader may do, cached in two tiers. Every unknown resolves to *no* permission. |
| Chrome | `NavigationSplitView`; the sidebar column is painted with **nothing**, which is where the wallpaper and menu-bar accent come through. |
| Timeline / Members | AppKit canvases with viewport-sized backing. |

---

## The performance model, in one page

The cost of a client like this is **node count and invalidation count**, not leaf
functions. Its predecessor measured 53 self-samples of 2,264 at idle and 450 of
~35,000 while scrolling in its own code — chasing hot functions there finds
nothing. So the design attacks the two things that actually cost:

**Fewer nodes.** The transcript and the member list are drawn, not composed. One
AppKit view paints rows into a dirty rect. A five-hundred-member roster is five
hundred rows of avatar, name, badges and activity line; as views that is several
thousand nodes for the forty a column shows.

**The viewport-sized canvas.** The document view is the full content height, so
the scroller is right. The canvas inside it is only `viewport + 2 × 320pt`, with
`bounds.origin` pinned to `frame.origin` so drawing stays in document
coordinates. It **only moves when it is about to run out of overscan** — between
moves the clip view slides over a static layer and the GPU does the entire
scroll. `TimelineViewportPolicy` is a pure function and the rule is pinned by
tests.

**Fewer invalidations.** Every surface has a thin container that reads the store
and hands a *plain value snapshot* to a view with no model reference, then
`.equatable()` over it. Because those snapshots come from memos, `Array ==`
short-circuits on buffer identity: a presence flush that moved nobody costs one
pointer comparison, not forty rebuilt rows.

**One gate for optional work.** `ScrollWorkGate` is process-wide and
continuation-based. Image prefetching, animation decoding and catalog refreshes
all `await` it, so a scroll anywhere suspends optional work everywhere — without
polling.

**Decode at the drawn size, off-main.** `NSImage(data:)` does not decode; it
defers to the first draw, on the main thread, inside a display pass.
`ImageStore` decodes through `CGImageSourceCreateThumbnailAtIndex` with
`kCGImageSourceShouldCacheImmediately`, keys the cache on *pixel size*, and
bounds concurrency so peak memory is not set by scroll speed.

**One accessibility node per message.** SwiftUI re-resolves every `Text` carrying
link attributes into an attributed string on *every render* — and a message
paragraph always carries them. It reaches localized bundle string tables to
answer what font a run is in, per run, per frame, and it is **not** conditional
on VoiceOver. `MarkdownDocument.plainText` folds the tree once so each row is one
node with a plain `String` label.

Measured on this build, `--demo`, 220 messages resident, release: **97–106 MB
steady** (`footprint`, not RSS), settling downward across a run. The peak sits
around 230 MB and is the fixture bootstrap, not the steady state. Its predecessor
sat at 300–425 MB.

---

## What is here

- Sign-in through Discord's own page, token in the Keychain
- Guild rail with folders, unread pips and mention badges
- Channel list: stretchy banner, travelling server-name pill, glass category
  chips, selection pill that flows between rows
- Floating now bar and floating composer
- Drawn transcript: runs, day separators, unread divider, markdown, code blocks,
  quotes, lists, spoilers, links, inline emoji, jumbo emoji, stickers,
  attachments, reactions, rich embeds, Components V2 bodies, polls you can vote
  in, an app's buttons, and the sentences the client composes for a join, a boost
  or a pin
- A transcript that answers the pointer: a face or a name opens a profile, a
  mention opens theirs, an emoji or a sticker says what it is and where it came
  from, and a message link scrolls to its target and lights it
- Drawn member list: hoist groups, role colours, presence shapes, activity lines,
  and a reserved full-row plate layer so nameplates drop in without reflowing
- Direct messages and group conversations, with a profile column beside one and a
  roster beside the other
- Mini and full profiles, and the cards behind a server tag and any expression —
  including the server behind an emoji or sticker from somewhere you are not in
- Expression picker with Nitro gating, and a `:shortcode` completion
- Typing receipts, a status panel on the now bar, and hover flyouts on the rail
- Settings with a live performance pane
- Performance inspector and a crash reporter that survives signal context

## What is not

Voice and video, threads, forums, search, notifications, attachments *outbound*,
message-component interactions, and every Discord commerce surface. Each is a
case on an existing enum rather than a new branch — see `docs/HANDOFF.md`.

---

Wingcord is not affiliated with Discord. Using a third-party client is against
Discord's terms of service.
