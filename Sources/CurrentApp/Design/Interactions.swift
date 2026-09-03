import SwiftUI

// MARK: - Hover

/// Tracks hover and hands the state to a builder, animated.
///
/// Every hover in the app goes through here rather than each view keeping its
/// own `@State private var isHovering`. Two reasons: the fade is the same
/// everywhere, and — more importantly — hover on macOS fires a *lot*, and this
/// is one place to make sure the animation is attached to the boolean rather
/// than to the whole subtree.
struct Hoverable<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(isHovering)
            .onHover { hovering in
                // Animating the value, not the view, keeps the fade local. A
                // `withAnimation` here would invalidate everything above it,
                // which on a 60-row list once per mouse-move is real work.
                withAnimation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion)) {
                    isHovering = hovering
                }
            }
    }
}

extension View {
    /// A neutral fill that appears under the cursor. The one hover treatment in
    /// the app — rows, menu items, sidebar entries all use it, so hovering
    /// anywhere feels like the same gesture.
    func hoverFill(_ radius: CGFloat = Radius.s, active: Bool = true) -> some View {
        Hoverable { hovering in
            self.background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.fillSubtle)
                    .opacity(hovering && active ? 1 : 0)
            )
        }
    }
}

// MARK: - Press

/// Press feedback for a `Button` that should draw none of its own chrome —
/// a library row, a card, a settings tile.
///
/// **This is a `ButtonStyle`, and that is the whole point.** The first version
/// was a `ViewModifier` that added its own `DragGesture(minimumDistance: 0)` to
/// track the press. It scaled correctly and it silently broke clicking: a
/// zero-distance drag recognises on mouse-down and wins the gesture sequence,
/// so the `onTapGesture` sitting outside it never fired. Rows highlighted on
/// hover, showed their press, and then did nothing at all — which reads as the
/// selection being broken rather than as a gesture conflict.
///
/// Taking the press state from `configuration.isPressed` means there is exactly
/// one gesture involved, and it is the button's own.
///
/// The scale is deliberately tiny and the release is a spring, so letting go
/// feels like the control settling rather than snapping back. Reduce Motion
/// drops the movement and keeps the click.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = Motion.pressScale

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, scale: scale)
    }

    struct StyleBody: View {
        let configuration: Configuration
        let scale: CGFloat

        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
                .animation(
                    Motion.spring(Motion.instant, reduceMotion: reduceMotion),
                    value: configuration.isPressed
                )
        }
    }
}

extension View {
    /// `Button { … } label: { … }.pressable()`
    func pressable(scale: CGFloat = Motion.pressScale) -> some View {
        buttonStyle(PressableStyle(scale: scale))
    }
}

// MARK: - Surfaces

extension View {
    /// A raised surface: fill, hairline edge, top highlight, shadow.
    ///
    /// The top highlight is the detail that matters. A flat rounded rectangle on
    /// a dark background reads as a hole; the same rectangle with one 7%-white
    /// line along its upper edge reads as an object sitting on top of something.
    /// It costs nothing and it is most of why this app's popovers look solid.
    func raisedSurface(
        radius: CGFloat = Radius.l,
        fill: Color = Theme.raised,
        deep: Bool = false
    ) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .shadow(
                        color: deep ? Theme.shadowDeep : Theme.shadow,
                        radius: deep ? 32 : 14,
                        y: deep ? 14 : 6
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
            )
            .overlay(alignment: .top) {
                // Inset by the corner radius so the highlight stops before the
                // curve instead of running around it, which is what real
                // specular light does.
                Rectangle()
                    .fill(Theme.strokeHighlight)
                    .frame(height: Size.hairline)
                    .padding(.horizontal, radius)
                    .opacity(0.9)
            }
    }

    /// Sets a translucent content pane into the window's frame: rounded on all
    /// four corners, inset on all four sides, with the frame's colour filling the
    /// gutter around it and *nothing at all* behind it.
    ///
    /// This is what the app uses instead of hairlines between its columns. The
    /// old seams were a 1pt line with 4pt of padding either side, and that
    /// padding had no background — so what actually showed there was the desktop,
    /// blurred, in a bright strip down each side of the list. It read as a badly
    /// drawn divider from about 2013.
    ///
    /// The empty background is deliberate and load-bearing. A plain
    /// `.background(Theme.chrome)` behind the whole column would put an opaque
    /// grey between the pane's glass and the window blur, and the one see-through
    /// surface in the app would show that grey rather than the desktop. Hence the
    /// cutout.
    func insetPane(
        inset: CGFloat = Chrome.contentInset,
        radius: CGFloat = Radius.l
    ) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .padding(inset)
            .background(
                PaneCutout(inset: inset, radius: radius)
                    .fill(Theme.chrome, style: FillStyle(eoFill: true))
            )
    }

    /// A flat inset card — no shadow, just a fill and an edge. Used inside
    /// panels where a shadow would stack on the panel's own.
    func insetCard(radius: CGFloat = Radius.m, fill: Color = Theme.fillSubtle) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
            )
    }

    /// The focus ring. One treatment, everywhere something takes keyboard focus,
    /// drawn *outside* the control's own border so it never changes the
    /// control's size — a focus ring that reflows the layout is how a settings
    /// pane ends up jumping as you tab through it.
    func focusRing(_ focused: Bool, radius: CGFloat = Radius.m) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.accentRing, lineWidth: 2.5)
                .padding(-1.5)
                .opacity(focused ? 1 : 0)
                .animation(Motion.spring(Motion.instant), value: focused)
        )
    }
}

// MARK: - Entrance

/// The bubble. **Every** modal surface in the app enters with this one
/// transition, and none of them are allowed their own.
///
/// It is written against the phase-based `Transition` protocol rather than as
/// two `AnyTransition`s glued together with `.asymmetric`, because arriving and
/// leaving are genuinely different here — arriving scales from `popScale` and
/// resolves out of a soft blur, leaving just shrinks a hair and fades — and one
/// type that switches on the phase says that far more plainly than a pair of
/// combined transitions does.
///
/// The springiness is not in here. A transition only describes the *shape* of
/// the entrance; the bounce comes from the animation the presenting overlay
/// hands it, which is always `Motion.pop(presenting:)`. Forgetting that
/// animation is the one way to get this wrong: the transition still runs, but
/// linearly, and the surface slides in like a drawer.
struct PopTransition: Transition {
    var reduceMotion = false

    func body(content: Content, phase: TransitionPhase) -> some View {
        // Reduce Motion keeps the fade and drops the scale and the blur — the
        // surface still announces itself, it just doesn't move.
        if reduceMotion {
            content.opacity(phase.isIdentity ? 1 : 0)
        } else {
            content
                .scaleEffect(scale(for: phase))
                .blur(radius: phase == .willAppear ? Motion.popBlur : 0)
                .opacity(phase.isIdentity ? 1 : 0)
        }
    }

    private func scale(for phase: TransitionPhase) -> CGFloat {
        switch phase {
        case .willAppear: return Motion.popScale
        case .identity: return 1
        case .didDisappear: return Motion.popExitScale
        }
    }
}

extension View {
    /// `card.popTransition(reduceMotion: reduceMotion)` — see `PopTransition`.
    /// Needs `Motion.pop(presenting:)` on the presenting overlay to spring.
    func popTransition(reduceMotion: Bool = false) -> some View {
        transition(PopTransition(reduceMotion: reduceMotion))
    }
}

// MARK: - Cutout

/// A rectangle with a rounded rectangle punched out of the middle of it.
///
/// Filled even-odd, so only the ring between the two is painted. See
/// `insetPane` for why the middle has to be genuinely empty rather than
/// covered.
struct PaneCutout: Shape {
    var inset: CGFloat
    var radius: CGFloat

    /// The hole is drawn half a point tighter than the pane that sits in it.
    ///
    /// Two coincident antialiased curves leave a sub-pixel gap between them, and
    /// a gap here shows the window blur — a faint bright halo tracing the pane,
    /// which is the exact thing this whole arrangement exists to get rid of.
    /// Overlapping instead puts the pane's own glass over the frame colour for
    /// half a point, which nothing can see.
    private static let bleed: CGFloat = 0.5

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let hole = rect.insetBy(dx: inset + Self.bleed, dy: inset + Self.bleed)
        guard hole.width > 0, hole.height > 0 else { return path }
        path.addPath(
            Path(
                roundedRect: hole,
                cornerRadius: max(0, radius - Self.bleed),
                style: .continuous
            )
        )
        return path
    }
}

// MARK: - Divider

/// The app's hairline. `Divider()` picks up the system separator colour, which
/// is one of the loudest things in stock macOS dark mode.
///
/// Reserved for dividing *content* inside one surface. It is not how two
/// surfaces are told apart any more — see `insetPane`.
struct Hairline: View {
    var axis: Axis = .horizontal
    var color: Color = Theme.stroke
    /// Inset from the ends, so a divider inside a padded surface lines up with
    /// the content rather than running edge to edge.
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(
                width: axis == .vertical ? Size.hairline : nil,
                height: axis == .horizontal ? Size.hairline : nil
            )
            .padding(axis == .horizontal ? .horizontal : .vertical, inset)
    }
}
