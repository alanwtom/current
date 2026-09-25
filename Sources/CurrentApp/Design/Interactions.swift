import SwiftUI
import AppKit

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
///
/// **It grows out of whatever you clicked.** With an `origin`, the scale is
/// anchored on that point rather than on the surface's own centre, so the add
/// card comes out of the plus button and the remove dialog out of the trash
/// can, and each goes back into it on the way out. Opened from the keyboard
/// there is nothing to grow from, and it pops from the middle as before. See
/// `PresentationOrigin` for where the point comes from.
///
/// The anchor has to be worked out inside `visualEffect`, because it is a
/// fraction of the surface's own frame and the surface hasn't been laid out
/// when the transition is built. `visualEffect` hands over that frame at the
/// moment of drawing, and never touches layout — which matters here, since a
/// transition that resized anything would be re-measuring the window through
/// the entrance.
struct PopTransition: Transition {
    var reduceMotion = false
    /// Where the surface grows from, in the window's coordinates. Nil pops it
    /// from its own centre.
    var origin: CGPoint?

    func body(content: Content, phase: TransitionPhase) -> some View {
        // Reduce Motion keeps the fade and drops the scale and the blur — the
        // surface still announces itself, it just doesn't move.
        if reduceMotion {
            content.opacity(phase.isIdentity ? 1 : 0)
        } else if let origin {
            let scale = scale(for: phase, fromOrigin: true)
            content
                .visualEffect { effect, proxy in
                    effect.scaleEffect(scale, anchor: Self.anchor(for: origin, in: proxy.frame(in: .global)))
                }
                .blur(radius: phase == .willAppear ? Motion.popBlur : 0)
                .opacity(phase.isIdentity ? 1 : 0)
        } else {
            content
                .scaleEffect(scale(for: phase, fromOrigin: false))
                .blur(radius: phase == .willAppear ? Motion.popBlur : 0)
                .opacity(phase.isIdentity ? 1 : 0)
        }
    }

    private func scale(for phase: TransitionPhase, fromOrigin: Bool) -> CGFloat {
        switch phase {
        case .willAppear: return fromOrigin ? Motion.popScaleFromOrigin : Motion.popScale
        case .identity: return 1
        case .didDisappear: return fromOrigin ? Motion.popExitScaleToOrigin : Motion.popExitScale
        }
    }

    /// `origin` as a fraction of `frame`. Usually well outside 0…1 — the plus
    /// button is nowhere near the card it opens — and that is the point: an
    /// anchor outside the frame is what makes the scale travel.
    nonisolated static func anchor(for origin: CGPoint, in frame: CGRect) -> UnitPoint {
        guard frame.width > 0, frame.height > 0 else { return .center }
        return UnitPoint(
            x: (origin.x - frame.minX) / frame.width,
            y: (origin.y - frame.minY) / frame.height
        )
    }
}

extension View {
    /// `card.popTransition(reduceMotion: reduceMotion, from: origin)` — see
    /// `PopTransition`. Needs `Motion.pop(presenting:)` on the presenting
    /// overlay to spring.
    func popTransition(reduceMotion: Bool = false, from origin: CGPoint? = nil) -> some View {
        transition(PopTransition(reduceMotion: reduceMotion, origin: origin))
    }
}

// MARK: - Origin

/// Where the click that is opening a surface landed, if a click is opening it.
///
/// Read off the event AppKit is currently dispatching rather than recorded by
/// each button. A surface can be opened from half a dozen places — the plus
/// button, the trash can, a palette row, the magnet card's "Choose files" —
/// and every one of them would have to remember to report where it was. This
/// needs none of them to: if the thing that just happened was a click in the
/// main window, that's where the surface grows from.
///
/// Everything else is nil, deliberately, and the surface pops from its centre:
///
/// - a key press — there is nowhere on screen to grow from;
/// - a click in a menu, the menu bar panel, or any other window — the point is
///   in somebody else's coordinates;
/// - anything stale. A surface opened by an async task after the click has no
///   business growing out of wherever the pointer happened to be.
///
/// Read it **once**, when the surface is created — `@State private var origin
/// = PresentationOrigin.current()` — so leaving uses the same point arriving
/// did, however long the surface was up.
@MainActor
enum PresentationOrigin {
    /// How old the click may be. Generous enough for a state change that goes
    /// through a `Task` hop, far too short for a click that happened earlier.
    private static let maximumAge: TimeInterval = 0.5

    static func current() -> CGPoint? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseUp:
            break
        default:
            return nil
        }
        guard ProcessInfo.processInfo.systemUptime - event.timestamp < maximumAge,
              let window = event.window,
              // The main window is the only titled one. Menus, the menu bar
              // panel and the status item are all borderless.
              window.styleMask.contains(.titled), !(window is NSPanel),
              let content = window.contentView
        else { return nil }

        // SwiftUI's global space starts at the top left; AppKit's window space
        // starts at the bottom left, so the point is flipped on the way over.
        let local = content.convert(event.locationInWindow, from: nil)
        guard content.bounds.contains(local) else { return nil }
        return CGPoint(x: local.x, y: content.isFlipped ? local.y : content.bounds.height - local.y)
    }
}

// MARK: - Shake

extension View {
    /// Two small swings, once, each time `trigger` changes: "that didn't work".
    ///
    /// Offset only, so nothing is re-measured — the thing shaking is often in a
    /// row or the title bar, where a size change is dangerous. Reduce Motion
    /// drops it entirely; whatever shakes always changes colour as well, so
    /// the fact still arrives.
    func shake(trigger: Int, reduceMotion: Bool) -> some View {
        modifier(Shake(trigger: trigger, reduceMotion: reduceMotion))
    }
}

private struct Shake: ViewModifier {
    let trigger: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let still = reduceMotion
        return content.keyframeAnimator(initialValue: CGFloat.zero, trigger: trigger) { view, x in
            view.offset(x: still ? 0 : x)
        } keyframes: { _ in
            let step = Motion.shakeDuration / 5
            let d = Motion.shakeDistance
            KeyframeTrack {
                CubicKeyframe(-d, duration: step)
                CubicKeyframe(d, duration: step)
                CubicKeyframe(-d * 0.66, duration: step)
                CubicKeyframe(d * 0.4, duration: step)
                CubicKeyframe(0, duration: step)
            }
        }
    }
}

// MARK: - Ripple

/// One ring spreading out from a point and fading: "it arrived", "it's done".
///
/// Fires once per change of `trigger` and is invisible the rest of the time.
/// The ring is drawn by a shape rather than grown by a frame, so its line
/// stays a hairline as it spreads and its footprint is fixed at `to` — an
/// overlay that never changes size can't make anything re-measure.
///
/// Stroke only, never filled. A tinted disc spreading over the row would be
/// colour laid on colour, and a ring says "from here" better anyway.
struct Ripple: View {
    let trigger: Int
    var tint: Color
    /// Diameters. Starts at the size of whatever it comes from, so it leaves
    /// that thing's edge rather than crossing over it.
    var from: CGFloat
    var to: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let (still, from, to, tint) = (reduceMotion, from, to, tint)
        return Color.clear
            .frame(width: to, height: to)
            .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, progress in
                content.overlay {
                    // 0 at rest and 1 when finished are both invisible, so it
                    // doesn't matter which one the animator settles on.
                    if progress > 0, progress < 1, !still {
                        RingShape(diameter: from + (to - from) * progress)
                            .stroke(tint, lineWidth: 1.5)
                            .opacity(Motion.rippleOpacity * (1 - progress))
                    }
                }
            } keyframes: { _ in
                KeyframeTrack {
                    MoveKeyframe(0)
                    // Leaves fast and slows as it spreads, like a real ripple.
                    LinearKeyframe(
                        1,
                        duration: Motion.expressive,
                        timingCurve: .bezier(
                            startControlPoint: UnitPoint(x: 0.1, y: 0.6),
                            endControlPoint: UnitPoint(x: 0.3, y: 1)
                        )
                    )
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private struct RingShape: Shape {
        var diameter: CGFloat
        func path(in rect: CGRect) -> Path {
            Path(ellipseIn: CGRect(
                x: rect.midX - diameter / 2,
                y: rect.midY - diameter / 2,
                width: diameter,
                height: diameter
            ))
        }
    }
}

// MARK: - Light pass

/// A band of light that crosses the view once, left to right, each time
/// `trigger` changes. Clip it to the shape it sits on.
///
/// It is the single-shot form of the flow a progress bar carries while data
/// is moving (see `ProgressTrack`), used where something has just been
/// confirmed rather than is ongoing: a download finishing, the VPN shield
/// confirming. White over whatever is under it, so it brightens that colour
/// rather than adding one.
struct LightPass: View {
    let trigger: Int
    var color: Color = Theme.flowLight
    var duration: TimeInterval = Motion.expressive

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let band = max(width * 0.34, 12)
            let (still, color) = (reduceMotion, color)
            Color.clear
                .keyframeAnimator(initialValue: 0.0, trigger: trigger) { content, progress in
                    content.overlay(alignment: .leading) {
                        if progress > 0, progress < 1, !still {
                            LinearGradient(
                                colors: [color.opacity(0), color, color.opacity(0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: band)
                            .offset(x: -band + (width + band) * progress)
                        }
                    }
                } keyframes: { _ in
                    KeyframeTrack {
                        MoveKeyframe(0)
                        LinearKeyframe(1, duration: duration, timingCurve: .easeInOut)
                    }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Stretch

/// Something drawn across `lo…hi` on one axis, where each of the two edges
/// animates *on its own*.
///
/// This is the stretch in the motion vocabulary. A selection highlight whose
/// two edges travel on different springs leaves with its front edge first and
/// catches up with its back, which reads as a drop of water sliding into place
/// rather than a box being moved. `matchedGeometryEffect` can't do it: it
/// animates a frame, and a frame has one animation.
///
/// **How two edges get two animations.** A view's `animatableData` animates
/// with whatever transaction changed it, so each edge lives in its own view:
/// `LowEdge` animates `lo` and passes it down every frame, `HighEdge` animates
/// `hi` and draws. Change `lo` inside one `withAnimation` and `hi` inside
/// another, and each moves on its own curve. Change both in one, and it moves
/// like any other frame.
struct StretchSpan<Content: View>: View {
    var lo: CGFloat
    var hi: CGFloat
    var axis: Axis
    /// The other axis, fixed: the full width of a vertical highlight, say.
    var cross: ClosedRange<CGFloat>
    @ViewBuilder var content: () -> Content

    var body: some View {
        LowEdge(lo: lo, hi: hi, axis: axis, cross: cross, content: content())
    }

    private struct LowEdge: View, Animatable {
        var lo: CGFloat
        var hi: CGFloat
        let axis: Axis
        let cross: ClosedRange<CGFloat>
        let content: Content

        nonisolated var animatableData: CGFloat {
            get { lo }
            set { lo = newValue }
        }

        var body: some View {
            HighEdge(lo: lo, hi: hi, axis: axis, cross: cross, content: content)
        }
    }

    private struct HighEdge: View, Animatable {
        var lo: CGFloat
        var hi: CGFloat
        let axis: Axis
        let cross: ClosedRange<CGFloat>
        let content: Content

        nonisolated var animatableData: CGFloat {
            get { hi }
            set { hi = newValue }
        }

        var body: some View {
            let length = max(0, hi - lo)
            let span = cross.upperBound - cross.lowerBound
            content
                .frame(
                    width: axis == .horizontal ? length : span,
                    height: axis == .vertical ? length : span
                )
                .offset(
                    x: axis == .horizontal ? lo : cross.lowerBound,
                    y: axis == .vertical ? lo : cross.lowerBound
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// A selection highlight that stretches between the things it selects.
///
/// Sits in a `backgroundPreferenceValue` over a stack of choices and is handed
/// the selected choice's frame. When the *selection* changes it stretches —
/// the edge in the direction of travel on `Motion.stretchLead`, the trailing
/// one on `Motion.stretchTrail`, both critically damped, so it never
/// overshoots. When only the *geometry* changes — a seam dragged, a window
/// resized — it follows at once, because a highlight that stretched its way
/// after a resize would lag behind the thing it marks.
struct StretchHighlight<Key: Hashable, Content: View>: View {
    /// What is selected. A change here is what earns the stretch.
    var key: Key
    /// Where the selected choice is, in this view's own coordinates.
    var target: CGRect
    var axis: Axis
    /// False for changes that shouldn't animate at all — the palette's
    /// highlight following the pointer, which would only lag.
    var animated = true
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lo: CGFloat = 0
    @State private var hi: CGFloat = 0
    @State private var placedKey: Key?

    var body: some View {
        StretchSpan(lo: lo, hi: hi, axis: axis, cross: cross, content: content)
            .onAppear { snap(to: target) }
            .onChange(of: Placement(key: key, target: target)) { _, next in
                place(next)
            }
    }

    private struct Placement: Equatable {
        let key: Key
        let target: CGRect
    }

    private var cross: ClosedRange<CGFloat> {
        axis == .vertical ? target.minX...max(target.minX, target.maxX) : target.minY...max(target.minY, target.maxY)
    }

    private func edges(_ rect: CGRect) -> (CGFloat, CGFloat) {
        axis == .vertical ? (rect.minY, rect.maxY) : (rect.minX, rect.maxX)
    }

    private func snap(to rect: CGRect) {
        let (newLo, newHi) = edges(rect)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            lo = newLo
            hi = newHi
        }
        placedKey = key
    }

    private func place(_ placement: Placement) {
        let selectionMoved = placement.key != placedKey
        // An unmeasured frame, or the first real one, is a placement rather
        // than a move — see the "unmeasured means don't shrink yet" rule.
        guard selectionMoved, animated, placedKey != nil, hi > lo,
              placement.target.width > 0, placement.target.height > 0
        else { return snap(to: placement.target) }

        placedKey = placement.key
        let (newLo, newHi) = edges(placement.target)
        if reduceMotion {
            withAnimation(Motion.adaptive(Motion.quick, reduceMotion: true)) {
                lo = newLo
                hi = newHi
            }
            return
        }
        let lead = Motion.spring(Motion.stretchLead)
        let trail = Motion.spring(Motion.stretchTrail)
        if newLo >= lo {
            withAnimation(lead) { hi = newHi }
            withAnimation(trail) { lo = newLo }
        } else {
            withAnimation(lead) { lo = newLo }
            withAnimation(trail) { hi = newHi }
        }
    }
}

/// Carries the selected choice's frame up to the `StretchHighlight` that
/// draws behind it. Tagged per control, so a segmented picker inside a
/// palette row, say, can't hand its selection to the palette's highlight.
struct HighlightAnchorKey<Tag>: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Marks this choice as the one a `StretchHighlight` should sit behind,
    /// when `isSelected`.
    func highlightAnchor<Tag>(_ tag: Tag.Type, isSelected: Bool) -> some View {
        anchorPreference(key: HighlightAnchorKey<Tag>.self, value: .bounds) { isSelected ? $0 : nil }
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
