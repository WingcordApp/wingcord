import SwiftUI
import WingcordCore

// MARK: - Friends, Messages and Voice, over a game
//
// The biggest widget on the overlay and the one that opens the others: a click
// in it is what raises a chat window, and a click in its third tab is what joins
// a room.
//
// **The material is decided by `INVARIANTS.md` §1 and not by taste.** This is a
// reading surface — names, statuses, one line of somebody's last message — over
// a moving picture, and a translucent reading surface is legible over a terminal
// and unreadable over a game. So the panel is **opaque**, and the only glass on
// it is the strip that is not read: the tab control, which brings its own.
//
// What the panel is opaque *with* is the reader's own profile: `ProfileGround`
// turns `theme_colors`, or the pair quantised out of their artwork, into the
// same wash the profile card wears — and answers `.neutral` for an account with
// no theme, which is the app's ordinary near-black. That gate is Discord's own
// and is already in this tree: theming is Nitro **full**, not Nitro Basic, and
// an account that set no colours has them derived from its banner-then-avatar.
// See `AppModel.themeArtworkURL` and `PremiumTier.derivesProfileTheme`.
//
// **Composed rather than drawn**, unlike the transcript and the roster. Those
// are canvases because five hundred rows of avatar, name and badges is several
// thousand nodes; this shows about ten at a time inside a `LazyVStack`, which
// materialises what is on screen and nothing else. A fifth drawn canvas for ten
// rows would be the cost of §2 without the reason for it.

struct OverlaySidebarWidget: View {
    @Bindable var controller: OverlayController
    @Environment(AppModel.self) private var model

    /// Wide enough for a name, a line of what somebody is doing and a mark at
    /// the end of the row; narrow enough to leave the game visible beside it.
    static let width: CGFloat = 304
    /// Tall enough for ten rows under the header, short enough to clear the
    /// toolbar above and the clip feedback below on a 900-point display.
    static let height: CGFloat = 468

    var body: some View {
        let presentation = model.overlaySidebarPresentation
        VStack(spacing: 0) {
            OverlaySidebarHeader(identity: presentation.identity)
            controls
            Divider().opacity(0.4)
            OverlaySidebarList(
                presentation: presentation,
                tab: controller.sidebarTab,
                query: controller.sidebarQuery,
                ground: ground(for: presentation.identity),
                openChat: { model.openOverlayChat($0) },
                openPerson: { model.openOverlayChat(with: $0) },
                joinRoom: { model.joinOverlayRoom($0) }
            )
        }
        .frame(width: Self.width, height: Self.height)
        .background { OverlaySidebarGround(ground: ground(for: presentation.identity)) }
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(
                    ground(for: presentation.identity).borderStyle,
                    lineWidth: ground(for: presentation.identity).borderWidth
                )
                .allowsHitTesting(false)
        }
        // A panel this size over a game needs to read as lying on top of it.
        // The rim above is the light; this is the weight under it.
        .shadow(color: .black.opacity(0.4), radius: 18, y: 6)
        // The one route this surface needs, and it is asked once per run — see
        // `OverlayController.prepareIdentity`.
        .task { controller.prepareIdentity() }
    }

    private func ground(for identity: OverlayIdentity) -> ProfileGround {
        // A widget over somebody's game is chrome, not a profile page: it
        // keeps the app's dark ink whatever the reader's own colours are.
        ProfileGround(themeColorValues: identity.themeColorValues, followsAppTheme: true)
    }

    // MARK: The strip under the card

    private var controls: some View {
        VStack(spacing: Spacing.base) {
            // **`SegmentedPicker`, not a hand-rolled row of capsules.** It is
            // this app's vocabulary for "these segments switch views", it brings
            // its own Liquid Glass, and it carries the keyboard story. Nothing
            // may add a second material to it — §4 rule 2.
            SegmentedPicker(
                options: OverlaySidebarTab.allCases.map { .init($0, $0.title) },
                selection: $controller.sidebarTab
            )
            OverlaySidebarSearchField(
                query: $controller.sidebarQuery,
                prompt: controller.sidebarTab.searchPrompt
            )
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.bottom, Spacing.base)
    }
}

// MARK: - What the panel is made of

/// The reader's own colours, at the scale of a panel rather than a card.
///
/// **`ProfileGroundFill` is fitted for a profile card and is wrong here**, and
/// that is a fact about size rather than about taste. Its derived case runs the
/// person's colour from 0.36 to 0.59 down the surface — numbers solved against
/// Discord's own card, and correct there, where the card is small and the colour
/// *is* its identity. Over 468 points with ten rows of prose in it the same
/// numbers produce a beige slab: measured on the first capture, the list read as
/// text on tan and the pinned section headers read as dark stripes across it.
///
/// §1 decides it: this is a reading surface, and a reading surface is legible
/// first. So the colour behaves the way `ProfileGroundFill`'s own note says a
/// theme should — **a wash over the reading surface, not the surface itself** —
/// and it is spent where the identity is, at the head. By the first row the
/// ground is the app's ordinary canvas, which is also what lets a pinned header
/// be opaque without looking like a bar drawn across somebody's colour.
///
/// An account with no theme gets `Palette.surface`, flat: the app's own panel,
/// one step off the canvas, exactly as every other unthemed surface.
private struct OverlaySidebarGround: View {
    var ground: ProfileGround

    var body: some View {
        if let accent = ground.accentPair?.primary {
            Palette.canvas.overlay {
                LinearGradient(
                    stops: [
                        .init(color: accent.opacity(0.30), location: 0),
                        .init(color: accent.opacity(0.14), location: 0.22),
                        .init(color: accent.opacity(0), location: 0.46),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            Palette.surface
        }
    }
}

// MARK: - The reader, at the head of it

/// Banner, face, name, status.
///
/// **The banner fills the strip that would otherwise be a block of nothing**,
/// which is what Discord's own overlay leaves blank. Where there is no banner
/// the same strip takes `plateStyle` — the person's accent, which is the one
/// place `accent_color` belongs, because Discord derives it *from* a banner and
/// it is therefore exactly right as a stand-in for one.
private struct OverlaySidebarHeader: View {
    var identity: OverlayIdentity

    /// The artwork strip. Deep enough to read as a banner rather than as a
    /// coloured rule, shallow enough that ten rows still fit beneath it.
    private static let bannerHeight: CGFloat = 72
    private static let avatarSide: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            banner
            HStack(spacing: Spacing.base) {
                AvatarView(
                    url: identity.avatarURL,
                    monogram: identity.monogram,
                    side: Self.avatarSide,
                    decorationURL: identity.decorationURL
                )
                .overlay(alignment: .bottomTrailing) {
                    // **No plate here.** A `PresenceDot`'s plate is a disc of
                    // the window's background colour, and on a themed ground
                    // that is a grey blot stuck to somebody's face. The gap is
                    // cut out of the avatar instead, so what shows through is
                    // the panel's own colour — the same treatment the profile
                    // card uses over its banner.
                    PresenceDot(status: identity.status, side: 12, hasPlate: false)
                        .padding(2)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .offset(x: 2, y: 2)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(identity.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if let status = identity.customStatus, !status.isEmpty {
                        HStack(spacing: Spacing.hair) {
                            if let emoji = identity.customStatusEmoji {
                                InlineEmojiMark(emoji: emoji, side: 11)
                            }
                            Text(status)
                                .font(.system(size: 11))
                                .foregroundStyle(Ink.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(identity.status.label)
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.snug)
            // The avatar overhangs the banner, so the row is pulled up by half
            // of it. Derived rather than measured: both numbers are constants
            // here and one line of arithmetic cannot go stale — §2.
            .padding(.top, -Self.avatarSide / 2 - Spacing.base)
        }
        .padding(.bottom, Spacing.base)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(identity.displayName), \(identity.customStatus ?? identity.status.label)"
        )
    }

    private var banner: some View {
        RemoteImage(url: identity.bannerURL, side: OverlaySidebarWidget.width, bucket: .artwork) {
            // **A colour rather than a spinner.** The strip is decoration; a
            // placeholder that announces itself would be chrome about chrome.
            Rectangle().fill(
                ProfileGround(
                    themeColorValues: identity.themeColorValues,
                    followsAppTheme: true
                )
                .plateStyle(accentColorValue: identity.accentColorValue)
            )
        }
        .aspectRatio(contentMode: .fill)
        .frame(width: OverlaySidebarWidget.width, height: Self.bannerHeight)
        .clipped()
        .overlay {
            // **A scrim over the whole strip, not only its foot**, and the
            // stronger half of it is why: an account with no banner gets
            // `plateStyle`, which for a derived theme is that person's colour
            // FLAT — correct on a profile card, where the body below is themed
            // too, and a bright paint swatch at the head of a panel whose body
            // is near-black. Measured on the first capture: a 72-point block of
            // #C99C8A over a list that starts at #0A0A0C.
            //
            // It also gives the avatar sitting across the seam somewhere to
            // land, which is what the foot half was always for.
            LinearGradient(
                colors: [.black.opacity(0.22), .black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The field

/// The house search field: a raised capsule with a still-life specular edge,
/// which is what the discovery pane, the forum browser and Channels & Roles all
/// draw. **Not glass** — there is an opaque panel behind it, and §4 rule 3 is
/// what that would break.
private struct OverlaySidebarSearchField: View {
    /// **A binding, not a value plus a setter.** A stored closure property is a
    /// non-`Sendable` function value where `TextField` wants a main-actor
    /// isolated one — the same note the discovery field carries.
    @Binding var query: String
    var prompt: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Ink.tertiary)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear the search"))
            }
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: Metrics.compactControl)
        .background(Palette.surfaceRaised, in: .capsule)
        .specularEdge(in: Capsule())
        .contentShape(.capsule)
        .onTapGesture { isFocused = true }
    }
}
