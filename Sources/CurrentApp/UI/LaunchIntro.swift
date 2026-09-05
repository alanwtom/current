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

            // The drop is the fifth stroke and it arrives on the same beat as
            // the four lines — one stagger step later, the same easing, the
            // same span. It grows from nothing rather than travelling.
            //
            // Two other ways of doing this were tried and both are worse. Flown
            // in — born up in the stack and falling to rest — it was one object
            // moving through an otherwise still composition, and it pulled the
            // eye at the moment the mark should simply be finishing. Literally
            // traced, as a trimmed circular stroke, it cannot work: a dot's
            // finished shape *is* a single round cap, so the stroke paints most
            // of it on the first frame; cutting the cap flat to stop that turns
            // the sweep into a pie chart with hard radial edges. The lines get
            // away with a round cap because a cap is a small fraction of a long
            // line. A dot has no length to hide it in.
            //
            // Growing is the honest analogue: a line extends, a dot expands.
            //
            // It also fills straight into `context` rather than a copy of it.
            // The flown-in version took a copy so it could fade itself in, set
            // that copy's opacity instead of multiplying into the inherited
            // one, and so ignored the icon's own dissolve: at the end of the
            // intro the plate and the waves faded on schedule and the drop sat
            // there at full brightness, one bright dot alone on an empty
            // window, until the view was torn down. Nothing here needs its own
            // opacity now, so there is nothing left to get wrong.
            let drawn = stages.reduceMotion
                ? 1
                : easeOut(progress(
                    elapsed,
                    from: stages.dropStart,
                    over: stages.dropDraw
                ))
            if drawn > 0 {
                let diameter = Mark.dropSize * drawn
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: Mark.axis - diameter / 2,
                        y: Mark.dropRestY - diameter / 2,
                        width: diameter,
                        height: diameter
                    )),
                    with: shading
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
        /// The drop draws on over the same span a line does, one stagger step
        /// after the last of them — it is the fifth stroke, so it keeps the
        /// same rhythm rather than having a schedule of its own.
        var dropDraw: TimeInterval { waveDraw }
        var hold: TimeInterval { scaled(Motion.instant) }
        var fade: TimeInterval { scaled(reduceMotion ? Motion.quick : Motion.standard) }

        var dropStart: TimeInterval {
            reduceMotion ? 0 : Double(Mark.waves.count) * waveStagger
        }
        var fadeStart: TimeInterval {
            reduceMotion ? plateIn + hold : dropStart + dropDraw + hold
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
