import SwiftUI
import AppKit

/// The launch intro: the app icon assembles itself once, then hands off to the
/// window behind it.
///
/// The mark is the same geometry as `Scripts/make-icon.swift` — four current
/// lines narrowing as they fall, ending in a single drop — authored in the same
/// 1024 design space so the two can't drift apart visually. If you change the
/// icon, change the rows here too.
///
/// Two constraints shaped this file, and both are easy to undo by accident:
///
/// **It must not renegotiate the window's layout.** AGENTS.md explains how a
/// view that redraws differently every tick can crash the app outright. So the
/// entire intro is *one* `Canvas` with a fixed frame: the animation happens
/// inside the drawing, where AppKit never sees it, rather than through
/// per-frame `scaleEffect`/`frame` changes that would make the window re-measure
/// 60 times a second.
///
/// **Nothing here exceeds ~300 ms.** The app's motion rule caps single movements
/// at that, and the intro doesn't get an exemption — it is a *sequence* of
/// token-length movements (each line draws in `standard`, the drop falls in
/// `standard`), which is why the total lands near a second without any one gesture
/// feeling slow. There are no hand-typed durations below; every stage length is
/// a `Motion` token.
struct LaunchIntro: View {
    /// Called once the intro is finished, whether it played out or was skipped.
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Needed to pin down the window background colour before drawing — see
    /// `veilColor`.
    @Environment(\.self) private var environment

    @State private var start: Date?
    /// Shifts the clock forward when the intro is skipped, so a skip jumps
    /// straight to the fade rather than cutting the picture dead.
    @State private var skipShift: TimeInterval = 0
    /// Bumped on skip to restart the completion timer with the shorter budget.
    @State private var skipCount = 0
    @State private var keyMonitor: Any?

    /// The drawn icon's size. The plate itself is 824/1024 of this, so ~103pt
    /// of visible artwork — big enough to read as the icon, small enough not to
    /// feel like a splash screen.
    private let iconSize: CGFloat = 128

    var body: some View {
        let stages = Stages(reduceMotion: reduceMotion)

        TimelineView(.animation) { timeline in
            let elapsed = elapsed(at: timeline.date)
            let frame = Frame(stages: stages, veil: veilColor, iconSize: iconSize)
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                frame.draw(in: &context, size: size, elapsed: elapsed)
            }
        }
        // Fills the window, so the only thing that could change its size is the
        // window itself. Nothing inside ever asks for a different size.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Runs up behind the titlebar as well. Without this the slate stops at
        // the titlebar and leaves a slightly lighter band across the top, which
        // gives away that this is a window with its chrome emptied out rather
        // than one clean surface.
        .ignoresSafeArea()
        // Swallowing clicks is deliberate: the list is live behind the intro and
        // a click meant for "skip" should not also select a torrent.
        .contentShape(Rectangle())
        .onTapGesture { skip(stages: stages) }
        .accessibilityHidden(true)
        .task(id: skipCount) {
            if start == nil { start = .now }
            let untilDone = max(0, stages.total - elapsed(at: .now))
            try? await Task.sleep(for: .seconds(untilDone))
            guard !Task.isCancelled else { return }
            onFinished()
        }
        .onAppear {
            // A key press skips too, but the key still reaches the app — the
            // monitor returns the event untouched. Someone who launches and
            // immediately hits ⌘K shouldn't lose the keystroke to the intro.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                skip(stages: stages)
                return event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private func elapsed(at date: Date) -> TimeInterval {
        guard let start else { return 0 }
        return date.timeIntervalSince(start) + skipShift
    }

    private func skip(stages: Stages) {
        let now = elapsed(at: .now)
        guard now < stages.fadeStart else { return }
        skipShift += stages.fadeStart - now
        skipCount += 1
    }

    // MARK: - Drawing

    /// The app's own window surface, flattened to fixed components first.
    ///
    /// The resolve is load-bearing and has already cost one debugging session.
    /// Handing `Canvas` a live appearance-dependent colour looks correct and
    /// draws *nothing* — it comes out fully transparent inside a canvas, so the
    /// veil silently vanished and the library sat there visible behind the logo.
    /// A literal colour would work too, but then it would be wrong in one of
    /// the two themes.
    private var veilColor: Color {
        Color(Theme.chrome.resolve(in: environment))
    }

}

// MARK: - One frame

extension LaunchIntro {
    /// The whole intro as a pure function of elapsed time.
    ///
    /// Split out of the view deliberately. An animation you can only judge by
    /// launching the app and squinting at it is one that quietly drifts;
    /// `LaunchIntroRenderingTests` can ask this for the exact frame at 0.7 s
    /// and look at it. It also keeps the drawing honest about its inputs —
    /// everything it needs is stored here, so a frame cannot depend on
    /// anything but the clock.
    struct Frame {
        let stages: Stages
        let veil: Color
        let iconSize: CGFloat

        // MARK: - Drawing

        func draw(
                in context: inout GraphicsContext,
                size: CGSize,
                elapsed: TimeInterval
            ) {
            // Everything dissolves together at the end, including the veil.
            let exit = 1 - easeOut(progress(elapsed, from: stages.fadeStart, over: stages.fade))

            // The veil hides the window until the intro is done, so launch reads as
            // one moment instead of "app appears, then something animates on top".
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(veil.opacity(exit))
            )

            let appear = easeOut(progress(elapsed, from: 0, over: stages.plateIn))
            // The plate settles in from slightly small, and on the way out drifts
            // slightly large — receding into the app rather than being switched off.
            let scale = stages.reduceMotion
                ? 1
                : 0.94 + 0.06 * easeOut(progress(elapsed, from: 0, over: stages.plateSettle))
                    + 0.04 * (1 - exit)

            var icon = context
            icon.opacity = appear * exit
            icon.translateBy(x: size.width / 2, y: size.height / 2)
            // Negative y flips into the icon's bottom-left origin, so the row
            // numbers below can be copied straight from make-icon.swift.
            icon.scaleBy(x: iconSize / Mark.designSize * scale, y: -iconSize / Mark.designSize * scale)
            icon.translateBy(x: -Mark.axis, y: -Mark.designSize / 2)

            drawPlate(in: icon)
            drawMark(in: icon, elapsed: elapsed, stages: stages)
        }

        func drawPlate(in context: GraphicsContext) {
            var plate = context
            // In this flipped space negative y is downward on screen, which is
            // where a shadow belongs.
            plate.addFilter(.shadow(color: .black.opacity(0.28), radius: 90, x: 0, y: -40))
            plate.fill(
                Mark.plate,
                with: .linearGradient(
                    Gradient(colors: [Mark.plateTop, Mark.plateBottom]),
                    startPoint: CGPoint(x: 512, y: 924),
                    endPoint: CGPoint(x: 512, y: 100)
                )
            )
            // Same soft light from above the icon has, so the plate doesn't read as
            // flat paint.
            plate.fill(
                Mark.plate,
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.16), .white.opacity(0)]),
                    center: CGPoint(x: 512, y: 880),
                    startRadius: 0,
                    endRadius: 520
                )
            )
        }

        func drawMark(in context: GraphicsContext, elapsed: TimeInterval, stages: Stages) {
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Mark.markTop, Mark.markBottom]),
                startPoint: CGPoint(x: 512, y: 830),
                endPoint: CGPoint(x: 512, y: 210)
            )

            // Drawn *before* the waves, so the current paints over it.
            //
            // On top, the drop bulged out of the last line while it beaded up —
            // for about a tenth of a second the narrowest wave looked like it
            // had a growth on it. Behind, the same movement reads as the drop
            // gathering underneath the current and sliding clear of it, which is
            // what it is supposed to be. Nothing about the timing changed; only
            // which shape is in front.
            //
            // The drop beads off the narrowest line and falls the short distance
            // to where the current has come to a point — the one file the
            // streams add up to.
            //
            // It used to fall the whole stack, 401 units of a 1024 space, inside
            // one `Motion.quick`. Rendered frame by frame that is not a fall, it
            // is a teleport: with `easeOut` on top, 63% of the journey happened
            // in the first quarter of the time, so at 60fps you saw the drop
            // about twice — once somewhere in the middle of the lines, once
            // already arrived. Falling from the last line is 83 units, which is
            // a distance you can actually watch something cross.
            // `if`, not `guard ... return`: the drop is drawn first now, and an
            // early return here would take the waves with it — the icon would
            // stay empty until the drop's own stage began.
            let fall = stages.reduceMotion
                ? 1
                : fallEase(progress(elapsed, from: stages.dropStart, over: stages.dropFall))
            if fall > 0 {

                // Beading up is its own, faster movement, finished before the fall
                // is. Growing the whole way down read as the drop zooming toward the
                // viewer rather than falling away from the current — the reference
                // this was measured against never scales anything at all, and the
                // moment a size change outlasts the movement it belongs to, it stops
                // being weight and starts being a camera move.
                let bead = stages.reduceMotion
                    ? 1
                    : easeOut(progress(elapsed, from: stages.dropStart, over: stages.dropBead))

                let centerY = Mark.dropStartY + (Mark.dropRestY - Mark.dropStartY) * fall
                let diameter = Mark.dropSize * (0.62 + 0.38 * bead)
                var drop = context
                // Fades in over the first third of the fall, so it doesn't pop into
                // existence on top of the lines it is meant to be gathering from.
                //
                // Multiplied into what it inherited, not assigned over it. Assigning
                // discarded the icon's own `appear * exit` opacity, so at the end of
                // the intro the plate and the waves dissolved on schedule and the
                // drop did not — it sat there at full brightness, one bright dot
                // alone on an empty window, and then vanished when the view was torn
                // down. Every other element in here draws through the inherited
                // opacity; this was the only one that overwrote it.
                drop.opacity = context.opacity * min(1, bead * 2)
                drop.fill(
                    Path(ellipseIn: CGRect(
                        x: Mark.axis - diameter / 2,
                        y: centerY - diameter / 2,
                        width: diameter,
                        height: diameter
                    )),
                    with: shading
                )
            }

            // Each line draws left to right, staggered top to bottom: the current
            // arrives from above and narrows as it comes.
            for (index, wave) in Mark.waves.enumerated() {
                let drawn = stages.reduceMotion
                    ? 1
                    : easeOut(progress(
                        elapsed,
                        from: Double(index) * stages.waveStagger,
                        over: stages.waveDraw
                    ))
                guard drawn > 0 else { continue }
                context.stroke(
                    drawn >= 1 ? wave.path : wave.path.trimmedPath(from: 0, to: drawn),
                    with: shading,
                    style: StrokeStyle(lineWidth: wave.weight, lineCap: .round, lineJoin: .round)
                )
            }
        }

        // MARK: - Easing

        /// 0…1 for `elapsed` moving through a stage. Stages are driven off one clock
        /// rather than chained `withAnimation` calls, so a skip can move the whole
        /// composition forward at once.
        func progress(_ elapsed: TimeInterval, from startsAt: TimeInterval, over duration: TimeInterval) -> Double {
            guard duration > 0 else { return elapsed >= startsAt ? 1 : 0 }
            return max(0, min(1, (elapsed - startsAt) / duration))
        }

        /// Matches the feel of the app's critically damped springs: quick departure,
        /// no overshoot.
        func easeOut(_ t: Double) -> Double {
            1 - pow(1 - t, 3)
        }

        /// A fall. Gravity for most of the trip, with the last of the speed
        /// spent on landing: velocity peaks around 70% of the way down and
        /// reaches zero exactly at rest, so the drop neither bounces nor stops
        /// dead.
        ///
        /// `easeOut` is right for everything else in here and exactly wrong for
        /// this one movement — it decelerates the whole way, which is how
        /// something is *placed*, not how something is dropped. A symmetric
        /// ease-in-out fixes the direction but spends as long slowing down as
        /// speeding up, which reads as the drop being lowered on a wire.
        ///
        /// Blended rather than switched between the two halves. A piecewise
        /// version, accelerating to 85% and then braking, puts a step in the
        /// velocity at the join; you see it as a flinch just before the drop
        /// settles. This crossfades gravity into the landing with a cubic, so
        /// the curve is smooth the whole way and still covers only ~31% of the
        /// distance in the first half of the time.
        func fallEase(_ t: Double) -> Double {
            let gravity = t * t                  // accelerating downward
            let landing = 1 - (1 - t) * (1 - t)  // cushioning to a stop
            let blend = t * t * t                // the landing only takes over near the end
            return gravity * (1 - blend) + landing * blend
        }
    }
}

// MARK: - Timing

extension LaunchIntro {
    /// The intro's schedule, assembled entirely from `Motion` tokens.
    ///
    /// Full: lines draw (0 → .64), the drop beads off the last one and falls
    /// (.64 → .92), the whole icon holds for a beat, then dissolves — about
    /// 1.3s end to end.
    ///
    /// Reduce Motion: nothing travels. The finished icon fades up, holds, fades
    /// out — under half a second, and the app's identity still registers.
    struct Stages {
        let reduceMotion: Bool

        /// `CURRENT_INTRO_SLOWMO=6` stretches the whole intro so it can actually
        /// be looked at — a 1.3s animation is impossible to screenshot or judge
        /// frame by frame at real speed. Affects nothing in a normal launch.
        private static let slowmo: Double = {
            guard let raw = ProcessInfo.processInfo.environment["CURRENT_INTRO_SLOWMO"],
                  let value = Double(raw), value > 0 else { return 1 }
            return value
        }()
        private func scaled(_ duration: TimeInterval) -> TimeInterval { duration * Self.slowmo }

        var plateIn: TimeInterval { scaled(Motion.quick) }
        var plateSettle: TimeInterval { scaled(Motion.standard) }
        var waveStagger: TimeInterval { scaled(Motion.instant) }
        var waveDraw: TimeInterval { scaled(Motion.standard) }
        /// `standard`, not `quick`. The drop is the last thing that happens
        /// before the icon dissolves, and the reference this was measured
        /// against spends the same beat unhurried. It is still one token and
        /// still under the app's ~300 ms ceiling for a single movement.
        var dropFall: TimeInterval { scaled(Motion.standard) }
        /// The bead finishes well before the fall does, so the drop is at full
        /// size for most of its travel.
        var dropBead: TimeInterval { scaled(Motion.quick) }
        var hold: TimeInterval { scaled(Motion.instant) }
        var fade: TimeInterval { scaled(reduceMotion ? Motion.quick : Motion.standard) }

        var dropStart: TimeInterval {
            reduceMotion ? 0 : Double(Mark.waves.count - 1) * waveStagger + waveDraw
        }
        var fadeStart: TimeInterval {
            reduceMotion ? plateIn + hold : dropStart + dropFall + hold
        }
        var total: TimeInterval { fadeStart + fade }
    }
}

// MARK: - The mark

/// The logo's geometry, in the icon's 1024 design space.
///
/// Built once and reused every frame — a superellipse and four sampled waves is
/// a few hundred points, and there is no reason to rebuild them 120 times a
/// second.
private enum Mark {
    static let designSize: CGFloat = 1024
    static let axis: CGFloat = 512

    static let plateTop = Color(red: 0.137, green: 0.204, blue: 0.494)
    static let plateBottom = Color(red: 0.039, green: 0.059, blue: 0.165)
    static let markTop = Color(red: 0.561, green: 0.949, blue: 1.0)
    static let markBottom = Color(red: 0.247, green: 0.663, blue: 1.0)

    /// Rows copied from `make-icon.swift`: y, width, stroke weight.
    private static let rows: [(y: CGFloat, width: CGFloat, weight: CGFloat)] = [
        (y: 707, width: 392, weight: 58),
        (y: 597, width: 300, weight: 54),
        (y: 491, width: 208, weight: 50),
        (y: 389, width: 116, weight: 46),
    ]
    private static let waviness: CGFloat = 0.052

    static let dropSize: CGFloat = 78
    /// The icon's drop sits at rect y 267; this is its centre.
    static let dropRestY: CGFloat = 267 + dropSize / 2
    /// It beads off the *last* line — the narrowest one — rather than the top
    /// of the stack. Falling from the top meant crossing every wave on the way
    /// down, which both read as the drop passing in front of the current and
    /// gave it four times the distance to cover in one token's worth of time.
    static let dropStartY: CGFloat = rows[rows.count - 1].y

    static let waves: [(path: Path, weight: CGFloat)] = rows.map { row in
        var path = Path()
        let amplitude = row.width * waviness
        let half = row.width / 2
        // One full period per line, so every row crests in the same place and
        // the stack reads as one body of water.
        for i in 0...120 {
            let f = CGFloat(i) / 120
            let point = CGPoint(
                x: axis - half + row.width * f,
                y: row.y + amplitude * sin(f * 2 * .pi)
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return (path, row.weight)
    }

    /// Apple's icon shape is a squircle, not a rounded rect; n=5 is a close
    /// match and the difference shows at this size.
    static let plate: Path = {
        let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
        let n: CGFloat = 5
        let a = rect.width / 2, b = rect.height / 2
        var path = Path()
        let steps = 480
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
            let ct = cos(t), st = sin(t)
            let point = CGPoint(
                x: rect.midX + a * copysign(pow(abs(ct), 2 / n), ct),
                y: rect.midY + b * copysign(pow(abs(st), 2 / n), st)
            )
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }()
}
