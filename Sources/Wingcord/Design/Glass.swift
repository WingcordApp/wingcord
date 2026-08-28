import SwiftUI

// MARK: - The material vocabulary
//
// Every glass surface in Wingcord goes through one of the modifiers below, and
// each names the exact API it expands to. Nothing here invents a material: there
// are no semi-transparent images, no hand-rolled `NSVisualEffectView`s, no
// custom "glass-looking" views.
//
// That matters beyond purity. macOS ships a system-wide glass intensity control
// plus Reduce Transparency and Increase Contrast, and only the real APIs honour
// all three. A hand-rolled blur ignores every one of them and looks broken on
// someone else's Mac.
//
// FOUR STANDING RULES the compiler cannot enforce:
//
//   1. Apply these *after* layout and appearance modifiers. Padding and frame
//      first, glass last — the material needs the final geometry.
//   2. Never stack glass on glass. If two glass surfaces would overlap, merge
//      them in a `GlassEffectContainer` or make the lower one solid.
//   3. Never put an opaque fill behind a glass surface. If a surface reads as a
//      flat dark panel, something behind it is opaque or unlit — fix the
//      composition, do not thicken the material.
//   4. A `GlassEffectContainer` PROMOTES its glass elements above ordinary
//      siblings and renders them itself rather than in place. So an `.overlay`
//      attached *outside* a glass view draws underneath it, and a
//      hover-revealed control must never be a glass element inside a container —
//      the container ignores the opacity on the wrapper holding it and every
//      such control in the tree draws at once. Anything that must sit over glass
//      goes INSIDE the glass view's content, which means before the modifier.
//
// The deployment target is macOS 27, so glass is always available. There is no
// `#available` gating anywhere in this app and no non-glass fallback path.

extension View {

    // MARK: Chrome over ordinary content

    /// Floating chrome that is not itself clickable — a page-title capsule, a
    /// date separator, a status pill, a category header.
    ///
    /// `.glassEffect(.regular, in: shape)`
    func floatingChrome(in shape: some Shape = .capsule) -> some View {
        glassEffect(.regular, in: shape)
    }

    /// Anything clickable. `.interactive()` is what produces the native
    /// pointer-down highlight and lensing, which is also how this app satisfies
    /// "respond on press, never on release" for free.
    ///
    /// **Not for a card inside a scrolling list.** Interactive glass warps and
    /// highlights toward the cursor; on a row in a scroll view the cursor stands
    /// still while the row slides underneath it, so the displacement is
    /// recomputed every frame and the card visibly wobbles. Small discrete
    /// targets keep it — the displacement scales with the surface.
    ///
    /// `.glassEffect(.regular.interactive(), in: shape)`
    func interactiveChrome(in shape: some Shape = .capsule) -> some View {
        glassEffect(.regular.interactive(), in: shape)
    }

    // MARK: Chrome over media
    //
    // `.clear` wherever there is media or a lit ground behind the surface — over
    // a server banner, over a photo, over a video frame. This is the app's
    // identity: you see through the chrome and watch content lens as it passes
    // underneath.
    //
    // Over the near-black reading surface this choice is wrong and the control
    // vanishes; over artwork it is the whole reason the control reads as
    // floating rather than printed on the picture.

    /// `.glassEffect(.clear, in: shape)`
    func chromeOverMedia(in shape: some Shape = .capsule) -> some View {
        glassEffect(.clear, in: shape)
    }

    /// `.glassEffect(.clear.interactive(), in: shape)`
    func interactiveChromeOverMedia(in shape: some Shape = .capsule) -> some View {
        glassEffect(.clear.interactive(), in: shape)
    }

    /// Clear glass that still has to be *seen* at rest.
    ///
    /// The selection indicator is the case: it must refract what is underneath
    /// it, which rules out `.regular` — that blurs the label into mush — but a
    /// fully clear body over near-black is invisible when nothing is moving. The
    /// tint is part of the material, not a fill behind it; a fill under glass is
    /// what rule 3 forbids and is exactly what stops a surface lensing.
    ///
    /// `.glassEffect(.clear.tint(color), in: shape)`
    func chromeOverMedia(tinted color: Color, in shape: some Shape = .capsule) -> some View {
        glassEffect(.clear.tint(color), in: shape)
    }

    // MARK: Emphasis
    //
    // One or two per surface at most. A surface where three controls are tinted
    // has no emphasis at all.

    /// The accent or destructive control on a surface — Send, Accept,
    /// Disconnect, Delete.
    ///
    /// The 0.7 is deliberate and shared: a tint at full opacity stops reading as
    /// tinted glass and starts reading as a painted button.
    ///
    /// `.glassEffect(.regular.tint(color.opacity(0.7)).interactive(), in: shape)`
    func emphasisChrome(_ color: Color, in shape: some Shape = .capsule) -> some View {
        glassEffect(.regular.tint(color.opacity(0.7)).interactive(), in: shape)
    }

    // MARK: Structural surfaces
    //
    // Non-floating grounds: panel backgrounds, grouped row containers. These are
    // *not* glass — they are material behind content, so they take `.background`
    // rather than `.glassEffect`. Glass floats; structure sits.

    /// `.background(.ultraThinMaterial, in: shape)`
    func structuralSurface(in shape: some Shape = .rect(cornerRadius: Radius.glass)) -> some View {
        background(.ultraThinMaterial, in: shape)
    }

    /// Grouped settings rows and other quiet containers.
    ///
    /// `.background(.regularMaterial, in: shape)`
    func groupedSurface(in shape: some Shape = .rect(cornerRadius: Radius.glass)) -> some View {
        background(.regularMaterial, in: shape)
    }

    // MARK: Specular

    /// A fixed sheen along a surface's upper edge, for surfaces that sit still.
    ///
    /// Moving glass picks up the system's own specular response as it travels. A
    /// search field never moves, so it has no leading edge and gets nothing — on
    /// a near-black ground that leaves a capsule with no edge at all, just a
    /// slightly lighter region.
    ///
    /// This is the still-life version: light from above, so the top of the shape
    /// catches it, the sides fall off fast, the bottom is dark. Kept under a
    /// point wide and well under full white — it should read as an edge
    /// existing, not as a border drawn.
    func specularEdge<S: InsettableShape>(
        in shape: S = Capsule(),
        intensity: Double = 0.28
    ) -> some View {
        overlay {
            shape
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(intensity), location: 0),
                            .init(color: .white.opacity(intensity * 0.3), location: 0.4),
                            .init(color: .clear, location: 0.85),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Scroll edges
//
// Progressive blur is app-wide, not per-surface. Every scrolling surface gets a
// soft scroll edge wherever content passes under floating chrome.
//
// THE PRECONDITION, and it is the whole reason this app has a real toolbar:
// `scrollEdgeEffectStyle` treats content at a scroll view's boundary *with a
// registered bar*. A hand-drawn band overlaid on a stack is not a bar, so the
// effect has nothing to key off and silently does nothing — and the surface then
// grows its own blur, its own height constant and a content-margin reservation
// at every scroll view beneath it. Register the bar (a real `.toolbar`, or
// `.safeAreaBar`) and the system does all of it.
//
// The failure mode is invisible at rest: scrolled to the top there is no content
// behind the bar to blur. Check it scrolled.

extension View {
    /// `.scrollEdgeEffectStyle(.soft, for: edges)`
    func softScrollEdges(_ edges: Edge.Set) -> some View {
        scrollEdgeEffectStyle(.soft, for: edges)
    }

    /// The default for a vertical list sitting under a header and above a
    /// floating bar — which is nearly every list in this app.
    func softScrollEdgesVertical() -> some View {
        scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }

    /// Horizontal scrollers that run edge to edge.
    func softScrollEdgesHorizontal() -> some View {
        scrollEdgeEffectStyle(.soft, for: [.leading, .trailing])
    }

    /// `.scrollEdgeEffectStyle(.hard, for: edges)`
    ///
    /// **`.soft` renders nothing when the bar carries no material of its own.**
    /// Measured, over a bar that is a floating capsule on an otherwise
    /// transparent row: content passing underneath stays sharp and fully lit,
    /// because what `.soft` draws is the bar's own material feathered downward,
    /// and there is no material to feather. `.hard` synthesises the band
    /// instead, which is the whole reason the two styles are not
    /// interchangeable. A bar that *does* carry a material wants `.soft`.
    ///
    /// **Neither style samples the CONTENT.** Both take the window's backdrop,
    /// so over a translucent window the band shows a blurred desktop and the
    /// rows passing under it vanish rather than being veiled. The settings pane
    /// therefore uses neither, and draws its own band — see
    /// `SettingsDetailPane.scrollEdgeBand` and the write-up in
    /// `docs/HANDOFF.md`.
    func hardScrollEdges(_ edges: Edge.Set) -> some View {
        scrollEdgeEffectStyle(.hard, for: edges)
    }
}

// MARK: - Floating bars
//
// `safeAreaBar`, not `safeAreaInset`. The two look interchangeable and are not:
//
//   - `safeAreaInset` only *reserves space*. The scroll view stops short of the
//     bar and nothing else happens.
//   - `safeAreaBar` additionally REGISTERS the view as a bar, which is what the
//     scroll edge effect keys off. Content passing underneath gets the system's
//     progressive blur; without it, rows slide under the chrome sharp and
//     unreadable and `scrollEdgeEffectStyle` does nothing at all.
//
// Attaching the bar *as* the inset is also what makes the inset and the bar
// unable to disagree, which is the bug every hand-reserved clearance eventually
// grows.

extension View {
    /// The floating composer, and any other bar along the bottom edge.
    func floatingBottomBar(
        spacing: CGFloat = 0,
        @ViewBuilder _ bar: () -> some View
    ) -> some View {
        safeAreaBar(edge: .bottom, spacing: spacing, content: bar)
    }

    /// A floating header along the top edge, same treatment.
    func floatingTopBar(
        spacing: CGFloat = 0,
        @ViewBuilder _ bar: () -> some View
    ) -> some View {
        safeAreaBar(edge: .top, spacing: spacing, content: bar)
    }
}

// MARK: - The reading surface

extension View {
    /// The True Black ground the *detail* column sits on. Content is opaque and
    /// scrolls underneath glass; this is that opaque layer.
    ///
    /// **Never apply this to the sidebar column.** AppKit paints that column
    /// with behind-window vibrancy, and that vibrancy is the bleed — the
    /// wallpaper and the menu-bar accent coming through the rail and the channel
    /// list. Painting over it is how an app ends up hand-rolling the effect the
    /// system was already giving it for free.
    func readingSurface() -> some View {
        background(Palette.canvas)
    }
}
