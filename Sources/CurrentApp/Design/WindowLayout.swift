import SwiftUI

/// The window's layout arithmetic, pulled out of the views that use it.
///
/// **This exists because of a class of bug you can only find by resizing.** The
/// settings card is a fixed 760×540, and in a smaller window it simply drew past
/// the edges: clipped on all four sides, its close button and its buttons off
/// screen, and no way out except resizing a window whose controls were now
/// underneath the card. The same shape of bug was waiting in the columns — drag
/// the sidebar and the inspector to their maximum widths and shrink the window
/// to 690pt, and the library between them is asked to be *minus fifty points
/// wide*.
///
/// Neither is visible in a screenshot of a comfortable window, and neither is a
/// state anyone thinks to try by hand. So the numbers that decide whether
/// something fits live here, as pure functions with no views attached, and
/// `WindowLayoutTests` sweeps them across window sizes rather than trusting a
/// single check at one size.
///
/// Three rules hold everywhere in here:
///
/// 1. **Nothing is ever wider or taller than the space it's in.** Being clipped
///    is worse than being small, because clipping hides controls.
/// 2. **An unmeasured container means "don't shrink yet".** SwiftUI reports a
///    zero size on the first layout pass, and treating that as "very small"
///    collapses everything for a frame at launch.
/// 3. **Degrade in a stated order, and never in a jump.** A panel gives up its
///    slack before its minimum, and its minimum before it disappears.
enum WindowLayout {

    // MARK: - Compact

    /// Below this the sidebar plus a comfortable list no longer fit.
    static let enterCompactWidth: CGFloat = 620

    /// Leaving compact deliberately needs more room than entering it. Without
    /// that gap a window parked exactly on the threshold flickers between the
    /// two layouts as it's dragged — and in this app a layout that changes on
    /// its own, repeatedly, is the thing that has taken the window down twice.
    static let leaveCompactWidth: CGFloat = 690

    static func isCompact(width: CGFloat, wasCompact: Bool) -> Bool {
        // A zero or negative width is a measurement that hasn't happened yet,
        // not a very narrow window.
        guard width > 0 else { return wasCompact }
        return wasCompact ? width < leaveCompactWidth : width < enterCompactWidth
    }

    // MARK: - Columns

    /// What the three columns actually get.
    struct Columns: Equatable {
        var sidebar: CGFloat
        var inspector: CGFloat
        var content: CGFloat

        /// Always the full window width, so the row can't leave a gap or
        /// overflow. Worth asserting in tests rather than trusting.
        var total: CGFloat { sidebar + inspector + content }
    }

    /// Resolves the stored column widths against the window that has to hold
    /// them.
    ///
    /// The saved widths are *preferences*, not results. They're whatever the
    /// user last dragged a seam to, and they were saved without any knowledge of
    /// how big the window would be next time — so this is where they meet
    /// reality. The library gives up nothing until both panels have given up
    /// everything, because the library is the app; the inspector goes first
    /// because it describes a row you can still see in the column it's crowding.
    static func columns(
        windowWidth: CGFloat,
        sidebar: CGFloat,
        inspector: CGFloat,
        showsSidebar: Bool,
        showsInspector: Bool,
        minimumContent: CGFloat,
        minimumSidebar: CGFloat,
        minimumInspector: CGFloat
    ) -> Columns {
        var sidebarWidth = showsSidebar ? max(0, sidebar) : 0
        var inspectorWidth = showsInspector ? max(0, inspector) : 0

        guard windowWidth > 0 else {
            return Columns(sidebar: sidebarWidth, inspector: inspectorWidth, content: 0)
        }

        var deficit = minimumContent - (windowWidth - sidebarWidth - inspectorWidth)

        // Step one: slack. Each panel shrinks towards its own minimum, in order.
        shrink(&inspectorWidth, toNoLessThan: minimumInspector, deficit: &deficit)
        shrink(&sidebarWidth, toNoLessThan: minimumSidebar, deficit: &deficit)

        // Step two: the window is genuinely too small for both panels *and* a
        // usable list. Both give way together rather than one vanishing for the
        // sake of the other's last few points — a panel that disappears while
        // you're still dragging reads as a glitch.
        if deficit > 0 {
            let remaining = sidebarWidth + inspectorWidth
            if remaining <= deficit {
                sidebarWidth = 0
                inspectorWidth = 0
            } else if remaining > 0 {
                let scale = 1 - deficit / remaining
                sidebarWidth *= scale
                inspectorWidth *= scale
            }
        }

        return Columns(
            sidebar: sidebarWidth,
            inspector: inspectorWidth,
            content: max(0, windowWidth - sidebarWidth - inspectorWidth)
        )
    }

    private static func shrink(
        _ width: inout CGFloat,
        toNoLessThan minimum: CGFloat,
        deficit: inout CGFloat
    ) {
        guard deficit > 0, width > minimum else { return }
        let taken = min(deficit, width - minimum)
        width -= taken
        deficit -= taken
    }

    // MARK: - Modal surfaces

    /// The size a modal card is allowed to be in the window it's centred in.
    ///
    /// `minimum` is a floor with a ceiling of its own: a card refuses to shrink
    /// below it *until* the window is smaller than that, at which point the card
    /// matches the window exactly and gives up its margin. That's deliberate —
    /// at some point there is no good answer, and "exactly the window, no
    /// margin" is the least bad one, because the alternative is a card whose
    /// buttons are off screen.
    static func modalSize(
        preferred: CGSize,
        container: CGSize,
        margin: CGFloat,
        minimum: CGSize
    ) -> CGSize {
        CGSize(
            width: modalExtent(preferred.width, container.width, margin, minimum.width),
            height: modalExtent(preferred.height, container.height, margin, minimum.height)
        )
    }

    private static func modalExtent(
        _ preferred: CGFloat,
        _ container: CGFloat,
        _ margin: CGFloat,
        _ minimum: CGFloat
    ) -> CGFloat {
        // Not measured yet — keep the preferred size rather than collapsing.
        guard container > 0 else { return preferred }
        let withMargins = container - margin * 2
        let floor = min(minimum, container)
        return min(preferred, max(withMargins, floor))
    }

    // MARK: - Settings rail

    /// Whether the settings card can afford two columns at all.
    ///
    /// The window is allowed to be a 380pt strip, and at that width a card with
    /// a rail down the side leaves a pane of about two hundred points — enough
    /// to wrap a download path one character per line. So below the width where
    /// both columns clear their own minimums the rail folds away entirely and
    /// the tabs move into the header, which is exactly what the main window's
    /// sidebar already does when it runs out of room.
    static func settingsShowsRail(
        cardWidth: CGFloat,
        minimumRail: CGFloat,
        minimumPane: CGFloat
    ) -> Bool {
        // Unmeasured: assume the roomy layout rather than flashing the narrow
        // one for a frame.
        guard cardWidth > 0 else { return true }
        return cardWidth >= minimumRail + minimumPane
    }

    /// The settings rail's width inside a card that may have been shrunk.
    ///
    /// Between "comfortable" and "no rail at all" the rail gives up width to
    /// keep the pane readable, down to a floor of its own — it still has to hold
    /// an icon and a word. Returns zero when there's no room for a rail; see
    /// `settingsShowsRail`.
    static func settingsRailWidth(
        cardWidth: CGFloat,
        preferred: CGFloat,
        minimum: CGFloat,
        minimumPane: CGFloat
    ) -> CGFloat {
        guard settingsShowsRail(cardWidth: cardWidth, minimumRail: minimum, minimumPane: minimumPane) else {
            return 0
        }
        guard cardWidth > 0 else { return preferred }
        return min(preferred, max(minimum, cardWidth - minimumPane))
    }

    // MARK: - Command palette

    /// The palette hangs from the top of the window rather than sitting in the
    /// middle of it, so its room is whatever is left under that offset — and in
    /// a short window the offset is the first thing that should go, because it's
    /// empty space and the list isn't.
    static func paletteLayout(
        containerHeight: CGFloat,
        preferredTop: CGFloat,
        preferredListHeight: CGFloat,
        chromeHeight: CGFloat,
        minimumListHeight: CGFloat,
        margin: CGFloat
    ) -> (top: CGFloat, listHeight: CGFloat) {
        guard containerHeight > 0 else { return (preferredTop, preferredListHeight) }

        var top = preferredTop
        var list = preferredListHeight
        var deficit = (top + chromeHeight + list + margin) - containerHeight

        shrink(&top, toNoLessThan: margin, deficit: &deficit)
        shrink(&list, toNoLessThan: minimumListHeight, deficit: &deficit)

        // Shorter than the palette's own furniture. Nothing sensible is left to
        // give, so stop taking — the list keeps one row and the surface is
        // clipped rather than inverted.
        return (max(0, top), max(0, list))
    }
}

// MARK: - The window's size, for the surfaces floating in it

extension EnvironmentValues {
    /// Published once by `AppShell` from its own geometry, so a modal surface
    /// can size itself against the window without every one of them measuring
    /// separately. Zero until the shell has measured — which `modalSize` reads
    /// as "keep your preferred size", not as "shrink to nothing".
    @Entry var windowSize: CGSize = .zero
}

extension View {
    /// **How a modal card states its size.** Use this instead of `.frame`.
    ///
    /// The numbers you pass are what the card wants; what it gets is those
    /// numbers resolved against the window, so it can't end up larger than the
    /// space it's centred in. Pass only the axes the card actually fixes — a
    /// dialog that sizes its own height passes `width:` alone.
    ///
    /// It has to be applied *by the card* rather than by `ModalSurface` around
    /// it, because a fixed `.frame` inside cannot be shrunk from outside: an
    /// inner fixed size wins over any outer maximum, which is exactly how the
    /// settings card ended up drawing past all four edges of a small window.
    func modalSize(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        modifier(ModalSizeModifier(preferredWidth: width, preferredHeight: height))
    }
}

private struct ModalSizeModifier: ViewModifier {
    let preferredWidth: CGFloat?
    let preferredHeight: CGFloat?

    @Environment(\.windowSize) private var windowSize

    func body(content: Content) -> some View {
        let fitted = WindowLayout.modalSize(
            preferred: CGSize(
                width: preferredWidth ?? .greatestFiniteMagnitude,
                height: preferredHeight ?? .greatestFiniteMagnitude
            ),
            container: windowSize,
            margin: Chrome.modalMargin,
            minimum: Chrome.modalMinSize
        )
        content.frame(
            width: preferredWidth == nil ? nil : fitted.width,
            height: preferredHeight == nil ? nil : fitted.height
        )
    }
}
