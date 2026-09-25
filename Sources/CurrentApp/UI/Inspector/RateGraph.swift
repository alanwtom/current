import SwiftUI
import CurrentCore

/// The inspector's throughput meter: the last minute and a half of one
/// torrent's traffic, as a column of bars either side of a baseline —
/// downloads below it, uploads above.
///
/// **Mirrored around a shared scale, and that is the whole idea.** The question
/// this panel exists to answer is not "how fast is this going" — the Transfer
/// group already says that in words — it is *what shape* the transfer is: is it
/// ramping up, has it stalled, is it giving back as fast as it takes. Two
/// stacked charts with their own axes cannot answer the third one, because a
/// 40 KB/s upload and a 4 MB/s download would draw the same mountain. One
/// baseline and one scale (`RateHistory.scale`) makes the halves directly
/// comparable, and the peak figure in the header says what the frame is worth
/// so the autoscale can't flatter a slow transfer.
///
/// **Bars, and the first version's failure is exactly why.** It was two
/// smoothed curves with gradient areas under them, and on real data — a
/// transfer holding a steady rate, which is most of them — it drew a solid
/// gradient slab with a flat line on top. Nothing about it read as time
/// passing; it read as a filled rectangle. Three properties fix that and none
/// of them is decoration:
///
/// - **Discrete bars have rhythm at any density.** Ninety of them across a
///   230pt panel is a 2.5pt slot — a 1.6pt bar and a 0.9pt gap — so even a
///   dead-constant rate is legibly ninety separate seconds rather than one
///   shape. It is also why the baseline is readable now: it shows *through*
///   the gaps instead of being buried under the densest end of two gradients.
/// - **Older bars fade.** A ramp from 40% at the left edge to full at the
///   right, which is what makes the meter read as flowing rather than as a
///   static histogram, and puts the emphasis on the seconds that still matter.
///   It hides nothing: every bar is above 40% and the scrub reads any of them
///   exactly.
/// - **Anything moving draws at least a stub.** A 2pt floor, so a direction
///   running at 3% of the scale is a row of small ticks rather than nothing at
///   all — which is the difference between "uploading a little" and "not
///   uploading", and at this size a fill of a third of a point is the latter.
///
/// Two more things are deliberate and easy to undo:
///
/// - **The frame never changes.** This is the only view in the app whose
///   content is redrawn on *every* engine tick, so it is the last place that
///   can afford to also re-measure — see the layout-churn section of AGENTS.md.
///   Every row is a fixed height, the two live numbers sit in fixed-width
///   slots, and the drawing happens inside a `Canvas` where AppKit never sees
///   it. The width is read with `onGeometryChange` and only changes when the
///   inspector's seam is dragged.
/// - **Hovering is a readout, not an action.** Dragging the cursor across the
///   meter scrubs the two figures back through the window. It has no keyboard
///   path and doesn't need one: every value it can reveal is already written
///   out on this panel, so the scrub adds detail rather than being the only
///   way to reach something.
struct RateGraph: View {
    let history: RateHistory

    @Environment(\.self) private var environment

    /// Where the cursor is along the meter, in points. Nil when it's elsewhere.
    @State private var scrubX: CGFloat?
    /// Read from the view rather than assumed, because the inspector is
    /// resizable — and only ever changes when someone drags the seam.
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            plot
            legend
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.m) {
            Text("THROUGHPUT")
                .typeStyle(Typo.overline)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: Space.m)
            // What the frame is worth, and so what the shape is worth.
            //
            // **Up here rather than down in the legend, because the legend is
            // where it wouldn't fit.** Three items on that row — two rates and
            // this — left it about fifty points in a default-width inspector
            // and it truncated to "PEAK 7…", which is the one reading on the
            // card that can't be guessed from the others. The header carries
            // two items and has room to spare.
            Text("PEAK \(ByteFormatting.rate(history.peak))")
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .numericTransition()
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
                .opacity(hasBars ? 1 : 0)
        }
        .frame(height: Size.pill)
    }

    // MARK: - The meter

    private var plot: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(&context, size: size)
        }
        .frame(height: Size.rateGraph)
        // **Clear of the zero line, not centred on it.** Both were centred, so
        // the line ran straight through the words and the caption read as
        // struck through — which looks like a rendering fault rather than like
        // an idle meter. It sits in the upper half now, where a silent
        // window's line is the one thing it can't collide with.
        .overlay(alignment: .top) {
            if !hasBars {
                Text(history.count == 0 ? "Waiting for the first readings…" : "Nothing moving")
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textQuaternary)
                    // Centred in the upper half. An idle window puts the zero
                    // line at the halfway mark, so this is the middle of the
                    // empty space above it.
                    .frame(height: Size.rateGraph / 2)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        // Scrubbing is off until there are bars: there would be nothing under
        // the cursor to read, and a guide travelling over an empty frame reads
        // as a control that has stopped working.
        //
        // Not animated, deliberately. A guide that eases towards the cursor
        // lags behind it, and the one thing a scrub has to be is exactly where
        // the pointer is.
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard hasBars else {
                scrubX = nil
                return
            }
            switch phase {
            case .active(let location): scrubX = location.x
            case .ended: scrubX = nil
            }
        }
        .contentShape(Rectangle())
    }

    /// There is something to draw bars for. A silent window is a flat line on
    /// the baseline, which on its own is indistinguishable from a meter that
    /// was never wired up — so it gets a caption instead.
    private var hasBars: Bool { history.count >= 1 && !history.isSilent }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let palette = Palette(environment: environment)
        // Where the ratio puts it, not the middle. Rounded so a 1pt line lands
        // on a pixel rather than across two, which at this weight is the
        // difference between a baseline and a smudge.
        let zero = (size.height * CGFloat(history.baselinePosition)).rounded()

        guard hasBars else {
            return baseline(&context, y: zero, width: size.width, palette: palette)
        }

        let samples = history.samples
        let metrics = Metrics(width: size.width, count: samples.count)
        let scrubbed = scrubIndex
        // How far each direction may travel before it runs into the frame. The
        // shares are proportional to the two peaks, so the tallest bar in each
        // direction lands at the same fraction of its own room — but the floor
        // in `baselinePosition` can widen the quiet side, so a length still
        // has to be clamped rather than trusted.
        let downRoom = size.height - zero - Metrics.baselineGap
        let upRoom = zero - Metrics.baselineGap

        // One shading per direction rather than per bar, so every bar is lit
        // by the same light: bright where it leaves the baseline, softer at the
        // tip. Per-bar gradients would make a tall bar and a stub look like
        // different materials.
        let downShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [palette.down, palette.down.opacity(0.45)]),
            startPoint: CGPoint(x: 0, y: zero),
            endPoint: CGPoint(x: 0, y: size.height)
        )
        let upShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [palette.up, palette.up.opacity(0.45)]),
            startPoint: CGPoint(x: 0, y: zero),
            endPoint: CGPoint(x: 0, y: 0)
        )

        drawPeakGuide(&context, size: size, zero: zero, palette: palette)

        for (index, sample) in samples.enumerated() {
            let x = metrics.centre(of: index)
            // The bar under the cursor is drawn at full strength whatever its
            // age, so scrubbing into the distant past still gives you
            // something solid to read against.
            let strength = index == scrubbed ? 1 : metrics.recency(of: index)

            if sample.down > 1, downRoom > 0 {
                fill(
                    &context,
                    bar: metrics.bar(
                        centredOn: x,
                        from: zero,
                        length: length(sample.down, room: downRoom, height: size.height),
                        downward: true
                    ),
                    with: downShading,
                    strength: strength
                )
            }
            if sample.up > 1, upRoom > 0 {
                fill(
                    &context,
                    bar: metrics.bar(
                        centredOn: x,
                        from: zero,
                        length: length(sample.up, room: upRoom, height: size.height),
                        downward: false
                    ),
                    with: upShading,
                    strength: strength
                )
            }
        }

        // **On top of the bars, not under them.** The zero line of a mirrored
        // meter is the one thing that cannot be missing — without it there is
        // nothing to tell you which half you are reading, and its height *is*
        // the give-and-take ratio — and the first version drew it first, where
        // the data went straight over it.
        baseline(&context, y: zero, width: size.width, palette: palette)

        if let scrubbed {
            let x = metrics.centre(of: scrubbed)
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                },
                with: .color(palette.scrub),
                lineWidth: Size.hairline
            )
        }
    }

    /// How long one bar is: its share of the whole frame, floored so a trickle
    /// still shows and capped so it can't leave its own side of the line.
    private func length(_ value: Double, room: CGFloat, height: CGFloat) -> CGFloat {
        min(room, max(Self.stub, CGFloat(history.fraction(value)) * height))
    }

    /// The shortest a bar is allowed to be. Two points, which is a bar rather
    /// than a smudge, and short enough that a trickle can't be mistaken for a
    /// real rate.
    private static let stub: CGFloat = 2

    private func fill(
        _ context: inout GraphicsContext,
        bar: Path,
        with shading: GraphicsContext.Shading,
        strength: Double
    ) {
        // Age is applied as context opacity rather than folded into the colour,
        // so the gradient above stays one object for the whole half instead of
        // being rebuilt ninety times.
        let restore = context.opacity
        context.opacity = strength
        context.fill(bar, with: shading)
        context.opacity = restore
    }

    /// The zero line. Every reading on this card is "how far from here".
    private func baseline(
        _ context: inout GraphicsContext,
        y: CGFloat,
        width: CGFloat,
        palette: Palette
    ) {
        context.stroke(
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            },
            with: .color(palette.baseline),
            lineWidth: Size.hairline
        )
    }

    /// A dotted line level with the tallest bar in the window.
    ///
    /// Part of what makes an autoscaling meter honest — the other part is the
    /// peak figure in the header. Without the pair of them the shape is
    /// unreadable in absolute terms: a torrent crawling at 30 KB/s and one
    /// flying at 30 MB/s draw the same bars, because the scale is the window's
    /// own peak in both cases. The guide shows *where* the tallest moment was
    /// and that the frame is scaled to it; the header says what it was worth.
    ///
    /// Under the bars rather than over them, unlike the baseline. It is a
    /// reference for the empty space beside the tall bar, not a line through
    /// the data, and drawn on top it cuts across every bar it passes.
    private func drawPeakGuide(
        _ context: inout GraphicsContext,
        size: CGSize,
        zero: CGFloat,
        palette: Palette
    ) {
        let peak = history.peak
        guard peak > 0 else { return }
        // Whichever direction actually hit the peak — the guide has to sit
        // level with the bar it describes, or it reads as an unrelated limit.
        let peakWasUp = history.upPeak >= history.downPeak
        let room = peakWasUp ? zero - Metrics.baselineGap : size.height - zero - Metrics.baselineGap
        guard room > 0 else { return }
        // Level with the tip of the tallest *bar*, which starts a gap clear of
        // the baseline — so the guide carries the same offset or it floats two
        // points off the thing it is measuring.
        let offset = Metrics.baselineGap + length(peak, room: room, height: size.height)
        let y = (peakWasUp ? zero - offset : zero + offset).rounded()

        context.stroke(
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            },
            with: .color(palette.guideLine),
            style: StrokeStyle(lineWidth: Size.hairline, dash: [2, 3])
        )
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: Space.m) {
            reading(symbol: "arrow.down", value: marked.down, tint: Theme.downloading, alignment: .leading)
            // Which slice of time the two rates either side of it describe —
            // the whole window at rest, and the moment under the cursor while
            // scrubbing. It sits between them because it qualifies both.
            //
            // **A flexible frame, not two `Spacer`s.** A spacer is greedier
            // than a `Text`, so a pair of them squeezes whatever is between
            // them until it truncates, however much room the row has.
            Text(windowLabel)
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .foregroundStyle(scrubIndex == nil ? Theme.textQuaternary : Theme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            reading(symbol: "arrow.up", value: marked.up, tint: Theme.seeding, alignment: .trailing)
        }
        .frame(height: Size.pill)
    }

    /// The arrow is tinted and the number beside it is not — the app's rule
    /// throughout: colour identifies, data stays on the grey ramp.
    private func reading(
        symbol: String,
        value: Double,
        tint: Color,
        alignment: Alignment
    ) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(value > 1 ? tint : Theme.textQuaternary)
            Text(ByteFormatting.rate(value))
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .numericTransition()
                .foregroundStyle(value > 1 ? Theme.textSecondary : Theme.textQuaternary)
        }
        // Fixed, so a rate crossing from 999 KB/s to 1.0 MB/s can't move the
        // other reading — or the time label between them — across the card.
        // 72pt fits "10.4 MB/s" and its arrow, and leaves the label room at
        // the inspector's narrowest (280pt, which is 228 inside the card).
        .frame(width: 72, alignment: alignment)
    }

    /// Seconds, spelled out, rather than `ByteFormatting.duration` — which
    /// rounds a 90-sample window to "1m" and would have the card claim a
    /// tidier number than it is actually showing.
    private var windowLabel: String {
        if let index = scrubIndex {
            let back = (history.count - 1 - index) * Int(RateHistory.sampleInterval)
            return back == 0 ? "now" : "−\(back)s"
        }
        return history.count == 0 ? "—" : "last \(Int(history.span))s"
    }

    // MARK: - Reading the window

    /// Which sample the legend is describing: the one under the cursor, or the
    /// newest one.
    private var marked: RateSample {
        guard let index = scrubIndex else { return history.latest }
        return history.samples[index]
    }

    private var scrubIndex: Int? {
        guard let scrubX else { return nil }
        return history.index(atX: scrubX, width: width)
    }

    private var accessibilityText: String {
        guard hasBars else { return "Throughput meter. Nothing moving." }
        let latest = history.latest
        return """
        Throughput over the last \(Int(history.span)) seconds. \
        Now downloading \(ByteFormatting.rate(latest.down)), \
        uploading \(ByteFormatting.rate(latest.up)). \
        Peak \(ByteFormatting.rate(history.peak)).
        """
    }

    // MARK: - Geometry

    /// Where the bars go, given a width and a number of samples.
    ///
    /// Separated out because all four numbers are related and getting any one
    /// of them alone is how a meter ends up with bars that touch at one
    /// inspector width and float apart at another.
    private struct Metrics {
        /// One slot per sample — **not** per gap between samples. A bar
        /// occupies time rather than marking an instant, so ninety of them
        /// need ninety slots; dividing by `count - 1` makes the last bar hang
        /// off the right-hand edge.
        let slot: CGFloat
        let barWidth: CGFloat
        let count: Int

        init(width: CGFloat, count: Int) {
            self.count = count
            slot = count > 0 ? width / CGFloat(count) : width
            // 62% bar, 38% gap. Tighter and the gaps close up into the slab
            // this replaced; looser and ninety bars read as a dotted line.
            // Capped at 3pt because a short window — fifteen samples in a wide
            // inspector — would otherwise draw fat blocks.
            barWidth = min(3, max(1, slot * 0.62))
        }

        func centre(of index: Int) -> CGFloat {
            slot * (CGFloat(index) + 0.5)
        }

        /// Full strength at the live edge, fading back through the window.
        ///
        /// Floored at 40%: the oldest bar has to stay legible, because it is
        /// data and not a backdrop.
        func recency(of index: Int) -> Double {
            guard count > 1 else { return 1 }
            let age = Double(index) / Double(count - 1)
            return 0.4 + 0.6 * age
        }

        /// How far a bar starts from the baseline.
        ///
        /// **Without this the meter is not mirrored, it is one row of sticks.**
        /// Both directions grew straight off the zero line, so an upload stub
        /// sat flush on top of a download bar and the pair read as a single
        /// bar with a green tip — the two facts the card exists to separate,
        /// drawn as one object, with the baseline buried under the joint. Two
        /// points of air fixes it and lets the zero line show through.
        static let baselineGap: CGFloat = 2

        /// One bar, with both ends rounded.
        ///
        /// Rounding the inner end too is technically wrong and invisible in
        /// practice — the radius is at most 1.5pt, and at that size a squared
        /// inner end just looks like a rendering artefact.
        func bar(centredOn x: CGFloat, from base: CGFloat, length: CGFloat, downward: Bool) -> Path {
            let start = downward ? base + Self.baselineGap : base - Self.baselineGap
            let rect = CGRect(
                x: x - barWidth / 2,
                y: downward ? start : start - length,
                width: barWidth,
                height: length
            )
            return Path(
                roundedRect: rect,
                cornerRadius: min(barWidth / 2, length / 2),
                style: .continuous
            )
        }
    }

    // MARK: - Colour

    /// The meter's colours, flattened before they reach the canvas.
    ///
    /// **The resolve is load-bearing.** Every colour in this app is a dynamic
    /// `NSColor` that answers to the window's appearance, and handing one of
    /// those straight to a `Canvas` draws *nothing at all* — it comes out fully
    /// transparent. `LaunchIntro` has the long version of that debugging
    /// session; this is the same trap.
    private struct Palette {
        let down: Color
        let up: Color
        let baseline: Color
        let guideLine: Color
        let scrub: Color

        init(environment: EnvironmentValues) {
            down = Color(Theme.downloading.resolve(in: environment))
            up = Color(Theme.seeding.resolve(in: environment))
            // **The text colour, not a stroke colour.** The bars meet this
            // line at their brightest, so it has to contrast with a saturated
            // fill rather than with the card — and the two stroke tokens are
            // translucent greys tuned for exactly the opposite job.
            // `strokeStrong` vanished completely.
            baseline = Color(Theme.text.resolve(in: environment)).opacity(0.32)
            guideLine = Color(Theme.textQuaternary.resolve(in: environment))
            scrub = Color(Theme.text.resolve(in: environment)).opacity(0.45)
        }
    }
}
