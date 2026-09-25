import SwiftUI
import CurrentCore

// MARK: - Progress track

/// The one progress bar used everywhere. Thin, capsule, colour = state.
///
/// It sits in a *well*, so an empty bar reads as an empty container rather than
/// as a lighter bar, and it has an indeterminate mode for a magnet that hasn't
/// resolved yet — so "no progress" and "we don't know yet" stop looking
/// identical.
///
/// It used to carry a soft glow in the fill's own colour. That went when the
/// palette stopped using hue for ordinary states: a coloured glow on a coloured
/// bar was decoration, and a *white* glow on a neutral bar is just a smudge. The
/// bar's length is the information.
///
/// The pulse is opacity only, and nothing here changes the view's size. A
/// progress bar whose *layout* changed on every engine tick is the kind of thing
/// that has killed this app before.
///
/// **It flows while data moves.** Hand it a `Flow` and a soft light runs along
/// the filled part — forwards for a download, backwards for a seed, which is
/// giving back — faster for a faster transfer. The point is not decoration: a
/// download that has stalled at 0 B/s looks, as a still bar, exactly like one
/// moving at 8 MB/s, and you had to read the number to tell them apart. Now the
/// stuck one is the one that isn't moving. The caller decides when there is a
/// flow (a rate above zero); the bar only draws it.
struct ProgressTrack: View {
    var fraction: Double
    var tint: Color
    var reduceMotion: Bool = false
    /// Unknown progress — pulses gently instead of showing a length.
    var indeterminate = false
    /// The unfilled part. Defaults to the value tuned for the library's canvas;
    /// surfaces that float above it need `Theme.trackRaised` instead.
    var track: Color = Theme.track
    /// Data moving along the bar, if any is. Nil draws a still bar.
    var flow: Flow?
    /// Bumped to send one pass of light along the fill — a download finishing.
    var passTrigger = 0

    /// Which way the light runs and how often it passes.
    struct Flow: Equatable {
        /// Seeding: data leaving, so the light runs back toward the start.
        var reversed = false
        /// Seconds per cycle, travel and rest together. One of the three
        /// `Motion.flowPass…` buckets — see `Motion.flowPeriod(for:)`.
        var period: TimeInterval
        /// 0…1, so a list of downloads doesn't pulse in lockstep.
        var seed: Double = 0

        /// The flow for a torrent in `state`: forwards while downloading,
        /// backwards while seeding, and none at all at 0 B/s — which is the
        /// point, since a stuck download is then the one bar standing still.
        ///
        /// Pass the snapshot as the UI has it, *after* the network block has
        /// zeroed its rates, so a torrent cut off from its connection stands
        /// still too.
        static func of(_ state: TorrentState, snapshot: TorrentSnapshot) -> Flow? {
            // Stable for a torrent within a run, different between torrents.
            let seed = Double(UInt(bitPattern: snapshot.id.hashValue) % 997) / 997
            switch state {
            case .downloading where snapshot.downloadRate > 1:
                return Flow(reversed: false, period: Motion.flowPeriod(for: snapshot.downloadRate), seed: seed)
            case .seeding where snapshot.uploadRate > 1:
                return Flow(reversed: true, period: Motion.flowPeriod(for: snapshot.uploadRate), seed: seed)
            default:
                return nil
            }
        }
    }

    @State private var pulsing = false

    var body: some View {
        GeometryReader { proxy in
            let clamped = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(track)

                if indeterminate {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(pulsing ? 0.45 : 0.14))
                } else {
                    Capsule(style: .continuous)
                        .fill(tint)
                        .overlay {
                            if let flow, !reduceMotion {
                                FlowLight(flow: flow)
                            }
                        }
                        .overlay { LightPass(trigger: passTrigger) }
                        .clipShape(Capsule(style: .continuous))
                        // Never narrower than its own corner radius, or a
                        // just-started download shows a sliver with clipped ends.
                        .frame(width: clamped > 0 ? max(clamped * proxy.size.width, 3) : 0)
                }
            }
        }
        .animation(Motion.spring(reduceMotion: reduceMotion), value: fraction)
        // Colour changes are their own beat: a download turning into a seed
        // shouldn't look like the bar jumped.
        .animation(Motion.adaptive(Motion.standard, reduceMotion: reduceMotion), value: tint)
        // **On the value, not just on appear.** This used to start the pulse in
        // `onAppear` alone, which is the one moment a bar is guaranteed *not*
        // to be indeterminate for a torrent restored from disk: it comes back
        // paused, and starts resolving a moment later, by which time the view
        // already exists and `onAppear` has been and gone. The bar then sat
        // frozen at 14% opacity forever — indistinguishable from a download
        // that had barely started and then stalled.
        .onAppear { startPulse() }
        .onChange(of: indeterminate) { _, _ in startPulse() }
    }

    private func startPulse() {
        guard indeterminate, !reduceMotion else { return }
        // Reset first, so a bar that goes indeterminate for a second time gets
        // a fresh animation rather than relying on the previous one still
        // running. Both assignments land in one update, so nothing flickers.
        pulsing = false
        withAnimation(.easeInOut(duration: Motion.expressive * 2).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}

/// The light a flowing bar carries, drawn per frame.
///
/// A `TimelineView` and a `Canvas` rather than a `repeatForever` animation, for
/// three reasons that all bit elsewhere first. The light's position is a pure
/// function of the clock, so a speed change never has to restart anything and
/// can't leave a half-finished animation behind. A `repeatForever` started in
/// `onAppear` inside a lazy list is a known way to have the list's own
/// insertions pick up the loop. And the drawing happens inside the canvas,
/// where AppKit never sees it — the only thing that changes per frame is
/// pixels, which is the one kind of change this app's layout can afford on
/// every tick.
private struct FlowLight: View {
    let flow: ProgressTrack.Flow
    /// Dynamic colours draw as transparent inside a `Canvas`; resolve first.
    @Environment(\.self) private var environment
    @State private var anchor: Anchor

    /// Where the light's cycle was at one moment, and at what speed.
    ///
    /// The position is counted from here rather than from the clock alone,
    /// because a rate hovering near a speed bucket's edge flips between two
    /// periods every few seconds — and computed straight from the clock, each
    /// flip put the light wherever the new period would have had it, so it
    /// teleported or vanished mid-bar. Re-anchored on every speed change, it
    /// just carries on from where it is, a little faster or slower. The period
    /// lives in here too, so no frame is ever drawn with the new speed against
    /// the old anchor.
    private struct Anchor {
        var time: TimeInterval
        var phase: Double
        var period: TimeInterval

        func phase(at time: TimeInterval) -> Double {
            phase + (time - self.time) / period
        }
    }

    init(flow: ProgressTrack.Flow) {
        self.flow = flow
        _anchor = State(initialValue: Anchor(
            time: Date().timeIntervalSinceReferenceDate,
            phase: flow.seed,
            period: flow.period
        ))
    }

    var body: some View {
        let light = Color(Theme.flowLight.resolve(in: environment))
        let current = anchor
        TimelineView(.animation) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let cycles = current.phase(at: timeline.date.timeIntervalSinceReferenceDate)
                let cycle = cycles - cycles.rounded(.down)
                // The rest of the cycle is a pause: a light that never rests
                // reads as a loading shimmer, something waiting, rather than
                // as something moving.
                guard cycle < Motion.flowTravelShare else { return }
                let linear = cycle / Motion.flowTravelShare
                let travel = linear * linear * (3 - 2 * linear)
                let band = max(size.width * 0.34, 10)
                let span = size.width + band
                let x = flow.reversed ? size.width - span * travel : -band + span * travel
                let rect = CGRect(x: x, y: 0, width: band, height: size.height)
                context.fill(
                    Path(rect),
                    with: .linearGradient(
                        Gradient(colors: [light.opacity(0), light, light.opacity(0)]),
                        startPoint: CGPoint(x: rect.minX, y: rect.midY),
                        endPoint: CGPoint(x: rect.maxX, y: rect.midY)
                    )
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: flow.period) { _, period in
            let now = Date().timeIntervalSinceReferenceDate
            anchor = Anchor(time: now, phase: anchor.phase(at: now), period: period)
        }
    }
}

// MARK: - State chip

/// Compact state indicator. The glyph carries the colour; the pill and the word
/// stay grey.
///
/// Kept as a pill rather than a bare word because a list of ten torrents in
/// five states needs the states to be scannable as shapes. The glyph swaps with
/// a symbol-effect replace transition, so pausing a download looks like the
/// pill changing rather than two pills crossfading.
///
/// **Ink, not surface.** This was a tinted pill with tinted text — a green
/// tick on a pale green capsule — which is the colour-on-colour shape the app
/// no longer uses anywhere. The colour moved into the glyph alone.
struct StatePill: View {
    let state: TorrentState
    /// Drops the word and keeps the glyph — for the compact layout.
    var glyphOnly = false
    /// Greys the glyph too. For a library row, whose own state glyph and
    /// progress bar already say this state in colour: a third coloured thing
    /// saying it again breaks the two-voices rule. See `quietInRow`.
    var quiet = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(quiet ? Theme.textTertiary : color)
                .contentTransition(.symbolEffect(.replace.offUp))
            if !glyphOnly {
                Text(label)
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, glyphOnly ? Space.xs : Space.m)
        .frame(height: Size.pill)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.fillMuted)
        )
        .animation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion), value: label)
        .accessibilityLabel(accessibilityText)
    }

    /// Whether a row already says this state in colour, so its pill should
    /// go quiet.
    ///
    /// A row tints its own glyph and bar for everything except the stopped
    /// states. The one stopped state with a colour of its own is "No
    /// connection" — amber, because it's the stop you can act on — and a row
    /// has no other amber to carry it, so that pill keeps its glyph.
    static func quietInRow(_ state: TorrentState) -> Bool {
        switch state {
        case .downloading, .checking, .seeding, .completed, .failed: return true
        case .paused, .resolving: return false
        }
    }

    private var symbol: String {
        switch state {
        case .resolving: return "sparkle.magnifyingglass"
        case .downloading: return "arrow.down"
        case .paused(.connectionUnavailable): return "network.slash"
        case .paused: return "pause.fill"
        case .seeding: return "arrow.up"
        case .completed: return "checkmark"
        case .checking: return "waveform.path.ecg"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var label: String {
        switch state {
        case .resolving: return "Resolving"
        case .downloading: return "Downloading"
        case .paused(let origin):
            switch origin {
            case .seedGoalReached: return "Goal met"
            case .battery: return "On battery"
            case .connectionUnavailable: return "No connection"
            default: return "Paused"
            }
        case .seeding: return "Seeding"
        case .completed: return "Done"
        case .checking: return "Checking"
        case .failed: return "Failed"
        }
    }

    private var color: Color {
        switch state {
        case .failed: return Theme.failure
        case .downloading, .checking: return Theme.downloading
        case .seeding: return Theme.seeding
        case .completed: return Theme.complete
        // Amber, not grey: this is the one stopped state you can do something
        // about, and what you do about it is outside the app — turn the VPN
        // back on. Grey would file it with "paused", which needs nothing.
        case .paused(.connectionUnavailable): return Theme.warning
        // Not a state so much as the absence of one.
        case .paused, .resolving: return Theme.textTertiary
        }
    }

    private var accessibilityText: String {
        if case .failed(let failure) = state {
            return "Failed: \(failure.title)"
        }
        return label
    }
}

// MARK: - Chip

/// A small neutral tag. Pinned markers, file counts, a policy name.
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: Space.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .semibold))
            }
            Text(text)
                .typeStyle(Typo.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Space.m)
        .frame(height: Size.pill)
        .background(Capsule(style: .continuous).fill(Theme.fillMuted))
    }
}

// MARK: - Spinner

/// An indeterminate spinner.
///
/// `ProgressView()` on macOS draws the system's grey pinwheel, which is both
/// unmistakably stock and slightly ugly at small sizes. This is an arc rotating
/// at a constant rate — a rotation, so it never touches layout.
struct Spinner: View {
    var size: CGFloat = 13
    var tint: Color = Theme.textSecondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(tint, style: StrokeStyle(lineWidth: max(1.4, size / 9), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .opacity(reduceMotion ? 0.6 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: Motion.revolution).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
            .accessibilityLabel("Working")
    }
}

// MARK: - Stat row

/// A label-and-value line, for the inspector.
///
/// The dotted leader is doing real work: it ties a label on the left to a number
/// on the right across a 300pt panel, which otherwise reads as two unrelated
/// columns. It is drawn at 20% so it registers as texture rather than as a line.
struct StatRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text(label)
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
            Leader()
            Text(value)
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .numericTransition()
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .fixedSize()
        }
        .frame(minHeight: 20)
    }

    private struct Leader: View {
        var body: some View {
            Rectangle()
                .fill(Theme.textQuaternary.opacity(0.35))
                .frame(height: Size.hairline)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 3)
        }
    }
}

// MARK: - Callout

/// A block of explanation. The app's one way of saying something important
/// inline — a failure, a rule that fired, a caveat in settings.
///
/// The card is neutral and only the glyph carries the tint. It used to be
/// washed in its own colour as well — a green icon on a pale green card for a
/// healthy swarm, red on pink for an error — which is colour on colour, and
/// said the same thing twice at a volume the text below it then had to fight.
struct Callout<Content: View>: View {
    var symbol: String
    var tint: Color = Theme.textSecondary
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: Size.iconSmall, weight: .semibold))
                .foregroundStyle(tint)
                // Nudged onto the first line's cap height. Top-aligned glyphs
                // sit visibly high next to 11pt text.
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Space.xs, content: content)
            Spacer(minLength: 0)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetCard(radius: Radius.m)
    }
}

/// A failure, with the technical message tucked behind a disclosure.
struct ErrorDetailsDisclosure: View {
    let failure: EngineFailure
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Callout(symbol: "exclamationmark.triangle.fill", tint: Theme.failure) {
            // The glyph beside this is already red. A red title as well was
            // the second voice for one fact.
            Text(failure.title)
                .typeStyle(Typo.label)
                .foregroundStyle(Theme.text)
            Text(failure.explanation)
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(Motion.spring(Motion.quick, reduceMotion: reduceMotion)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(expanded ? "Hide details" : "Details")
                }
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, Space.xs)

            if expanded {
                Text(failure.technicalMessage)
                    .font(.monoStyle)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                            .fill(Theme.well)
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Swarm health

struct SwarmHealthCard: View {
    let health: SwarmHealth
    let seeds: Int

    var body: some View {
        Callout(symbol: symbol, tint: color) {
            Text("\(health.label) · \(seeds) seed\(seeds == 1 ? "" : "s")")
                .typeStyle(Typo.label)
                .foregroundStyle(Theme.text)
            Text(health.explanation)
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var symbol: String {
        switch health {
        case .healthy: return "person.3.fill"
        case .moderate: return "person.2.fill"
        case .rare: return "person.fill.badge.minus"
        case .unknown: return "person.fill.questionmark"
        }
    }

    /// Amber rather than red for a rare swarm: it is a thing worth knowing and
    /// acting on, not a failure. Nothing is broken.
    ///
    /// An unmeasured swarm is grey, because colour in this app means a state and
    /// "we don't know" isn't one. In practice the callout isn't shown at all
    /// then — see `InspectorPanel` — but the case has to be neutral rather than
    /// alarming for the day something does show it.
    private var color: Color {
        switch health {
        case .healthy: return Theme.complete
        case .moderate: return Theme.textSecondary
        case .rare: return Theme.warning
        case .unknown: return Theme.textTertiary
        }
    }
}

// MARK: - Empty state

/// What a surface shows when it has nothing in it.
///
/// The glyph sits in a soft circular well rather than floating on the
/// background. A 44pt ultralight SF Symbol alone on a large empty area reads as
/// a missing image; giving it a container makes it read as an illustration.
struct EmptyStateView: View {
    var symbol: String = "tray"
    var title: String
    var message: String
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var shortcutHint: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Space.xl) {
            ZStack {
                Circle()
                    .fill(Theme.fillSubtle)
                Circle()
                    .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 56, height: 56)

            VStack(spacing: Space.m) {
                Text(title)
                    .typeStyle(Typo.title)
                    .foregroundStyle(Theme.text)
                Text(message)
                    .typeStyle(Typo.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }

            if let primaryTitle, let primaryAction {
                VStack(spacing: Space.m) {
                    Button(primaryTitle, action: primaryAction)
                        .currentButton(.primary)
                    if let shortcutHint {
                        KeyHint(shortcutHint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Rises once when the surface becomes empty. Not repeated, not looped —
        // an empty state that keeps moving is an empty state you can't ignore.
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : Motion.enterOffset)
        .onAppear {
            withAnimation(Motion.spring(Motion.standard, reduceMotion: reduceMotion)) {
                appeared = true
            }
        }
    }
}

// MARK: - Keyboard hint

/// A keyboard shortcut drawn as a key.
///
/// Every keyboard path in the app is visible somewhere, because a shortcut
/// nobody can see is a shortcut nobody uses. Drawing them as keycaps rather than
/// grey text is what makes them read as "press this".
struct KeyHint: View {
    let keys: String

    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .typeStyle(Typo.caption)
            .tabularNumerics()
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Space.m)
            .frame(height: Size.pill)
            .background(
                RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                    .fill(Theme.fillMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
            )
            .accessibilityLabel("Shortcut \(keys)")
    }
}
