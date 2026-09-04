import SwiftUI
import AppKit
import CurrentCore

// MARK: - Metrics

enum StatusPanelMetrics {
    /// Narrow on purpose. This hangs off the menu bar over whatever app you
    /// were using, so it has to read as a panel belonging to the menu bar
    /// rather than a second window that turned up.
    static let width: CGFloat = 340
    /// A row's fixed height. Fixed for the usual reason — see the layout-churn
    /// section of AGENTS.md — but also because the panel's window frame is set
    /// once when it opens, and a row that grew would be clipped by it.
    static let rowHeight: CGFloat = 58
    /// The most transfers listed before the rest become a "+N more" line. Five
    /// is where the panel stops being glanceable and starts being the library.
    static let maxRows = 5
    /// Gap between the menu bar and the top of the panel.
    static let menuBarGap: CGFloat = 6
    // MARK: Shadow room
    //
    // A window clips its own content, so a shadow drawn at the card's edge is a
    // shadow drawn at the window's edge. These margins are the transparent room
    // it falls into, and they have to be **larger than the shadow actually
    // reaches** — a blur of radius r spreads about 2r, plus its offset. Get
    // this wrong and the shadow doesn't look soft, it looks like a dark
    // rectangle with the card sitting in it, because that is exactly what a
    // clipped Gaussian is. That was the first version: 22pt of room for a
    // shadow that needed seventy.
    //
    // They're asymmetric because the shadow is. It falls downward, and the top
    // edge is tucked under the menu bar where there is nothing to catch it —
    // spending room up there would only push the window off the top of the
    // screen. `StatusItemController` accounts for all three when placing it.

    /// Blur radius. `2 × this + shadowDrop` is what it costs in room.
    static let shadowBlur: CGFloat = 22
    /// How far the shadow falls below the card.
    static let shadowDrop: CGFloat = 10
    static let shadowRoomTop: CGFloat = 22
    static let shadowRoomSide: CGFloat = 48
    static let shadowRoomBottom: CGFloat = 58
}

// MARK: - Model

/// What the menu bar panel draws, kept still enough to draw safely.
///
/// Two things matter here and both are the same lesson this app keeps
/// relearning. First, the panel's window frame is computed once when it opens,
/// so its content must not change *size* while it's open. Second, values inside
/// it update once a second, and anything that re-measures on every tick is how
/// this app has crashed before.
///
/// So the set of rows is **frozen when the panel opens** and only the numbers
/// inside them move. Which torrents count as "active" flickers constantly in
/// normal operation — one dropping to zero bytes a second and back is enough —
/// and without freezing, the list would reshuffle and resize under a stationary
/// cursor. This is the same fix the old notch card needed, for the same reason.
@MainActor
final class StatusPanelModel: ObservableObject {

    struct Row: Identifiable, Equatable {
        let id: TorrentID
        var name: String
        var progress: Double
        var downloadRate: Double
        var uploadRate: Double
        var etaSeconds: TimeInterval?
        var isPaused: Bool
        var isComplete: Bool
        var isSeeding: Bool

        /// Colour identifies what a row *is*. Numbers in the row stay grey.
        var tint: Color {
            if isPaused { return Theme.progressIdle }
            if isSeeding { return Theme.seeding }
            if isComplete { return Theme.complete }
            return Theme.downloading
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var hiddenCount = 0
    @Published private(set) var downloadRate: Double = 0
    @Published private(set) var uploadRate: Double = 0
    @Published private(set) var downloadingCount = 0
    @Published private(set) var seedingCount = 0
    @Published private(set) var totalCount = 0
    /// True when there is something running that Pause All would act on.
    @Published private(set) var hasActive = false
    /// The colour the menu bar icon is currently wearing, so the panel's own
    /// mark can wear it too. Derived from the same `LibraryActivity` the icon
    /// uses, rather than recomputed, so the two can't disagree.
    @Published private(set) var dominantTint: Color = Theme.textTertiary

    private var frozenIDs: [TorrentID]?
    private weak var library: LibraryStore?

    init(library: LibraryStore?) {
        self.library = library
    }

    /// Called as the panel opens: decides the row set, once.
    func freeze() {
        guard let library else { return }
        let ordered = Self.interesting(in: library)
        frozenIDs = Array(ordered.prefix(StatusPanelMetrics.maxRows)).map(\.id)
        hiddenCount = max(0, ordered.count - StatusPanelMetrics.maxRows)
        refresh()
    }

    func thaw() {
        frozenIDs = nil
    }

    /// Updates the numbers inside the frozen rows. Never changes how many
    /// there are.
    func refresh() {
        guard let library else { return }

        let snapshots = library.orderedIDs.compactMap { library.snapshot(for: $0) }
        downloadRate = library.aggregateDownloadRate
        uploadRate = library.aggregateUploadRate
        totalCount = snapshots.count
        downloadingCount = snapshots.filter {
            if case .downloading = $0.state { return true }
            return false
        }.count
        seedingCount = snapshots.filter {
            if case .seeding = $0.state { return true }
            return false
        }.count
        hasActive = snapshots.contains { $0.state.isActive }

        switch LibraryActivity.summarize(snapshots)?.dominant {
        case .downloading: dominantTint = Theme.downloading
        case .seeding: dominantTint = Theme.seeding
        case .complete: dominantTint = Theme.complete
        case .failed: dominantTint = Theme.failure
        case nil: dominantTint = Theme.textTertiary
        }

        let byID = Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let ids = frozenIDs ?? Array(Self.interesting(in: library).prefix(StatusPanelMetrics.maxRows)).map(\.id)
        rows = ids.compactMap { byID[$0] }.map(Self.row(from:))
    }

    /// Downloads first — those are what you opened this to check — then seeds,
    /// then anything else still going.
    private static func interesting(in library: LibraryStore) -> [TorrentSnapshot] {
        let snapshots = library.orderedIDs.compactMap { library.snapshot(for: $0) }
        let downloading = snapshots.filter {
            if case .downloading = $0.state { return true }
            return false
        }
        let otherActive = snapshots.filter { snapshot in
            snapshot.state.isActive && !downloading.contains { $0.id == snapshot.id }
        }
        let paused = snapshots.filter { $0.state.isPaused }
        return downloading + otherActive + paused
    }

    private static func row(from snapshot: TorrentSnapshot) -> Row {
        var isSeeding = false
        if case .seeding = snapshot.state { isSeeding = true }
        return Row(
            id: snapshot.id,
            name: snapshot.name,
            progress: snapshot.progress,
            downloadRate: snapshot.downloadRate,
            uploadRate: snapshot.uploadRate,
            etaSeconds: snapshot.etaSeconds,
            isPaused: snapshot.state.isPaused,
            isComplete: snapshot.state.isComplete,
            isSeeding: isSeeding
        )
    }
}

// MARK: - Panel

/// The menu bar panel.
///
/// **This is the one place the app draws its own "menu", and it is not one.**
/// Everywhere else the rule holds: `Menu`, `.contextMenu` and the menu bar's
/// own menus stay native, because a menu has to leave the window, traverse by
/// keyboard and behave like every other menu on the machine. What lives here
/// isn't a list of commands — it's live progress bars, per-transfer controls
/// and a rate readout, none of which an `NSMenu` can draw. The old version
/// tried and the result was a column of disabled text items reading
/// "6 active", which told you less than the menu bar icon already did.
struct StatusPanelView: View {
    @ObservedObject var model: StatusPanelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onTogglePause: (TorrentID) -> Void
    var onReveal: (TorrentID) -> Void
    var onOpenTorrent: (TorrentID) -> Void
    var onPauseAll: () -> Void
    var onResumeAll: () -> Void
    var onAdd: () -> Void
    var onOpenApp: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void
    var onDismiss: () -> Void

    @State private var shown = false

    var body: some View {
        card
            .padding(EdgeInsets(
                top: StatusPanelMetrics.shadowRoomTop,
                leading: StatusPanelMetrics.shadowRoomSide,
                bottom: StatusPanelMetrics.shadowRoomBottom,
                trailing: StatusPanelMetrics.shadowRoomSide
            ))
            // The margin is part of the window, so it swallows clicks that look
            // like they landed outside the panel. Giving it the dismiss action
            // makes it behave the way it looks.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
            )
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            summaryCard
            transfers
            footer
        }
        .frame(width: StatusPanelMetrics.width)
        .background(surface)
        .clipShape(shape)
        // Border and highlight go *outside* the clip, or the shape clips its own
        // edge to half a pixel and the whole thing loses its outline.
        .overlay(shape.strokeBorder(Theme.stroke, lineWidth: Size.hairline))
        .overlay(alignment: .top) {
            // The specular line, stopped short of the curve — real light doesn't
            // wrap a corner. Same trick every raised surface in the app uses.
            Rectangle()
                .fill(Theme.strokeHighlight)
                .frame(height: Size.hairline)
                .padding(.horizontal, Radius.xl)
        }
        // Wide and soft, thrown below the panel. This is what separates a
        // surface floating over another app from one pasted onto it, and it is
        // the reason the window carries transparent margins. Change either
        // number and the margins above have to grow to match.
        .shadow(
            color: Theme.shadowDeep,
            radius: StatusPanelMetrics.shadowBlur,
            y: StatusPanelMetrics.shadowDrop
        )
        // A second, tight one to seat the edge. Small enough that the margins
        // already cover it several times over.
        .shadow(color: Theme.shadow, radius: 3, y: 1)
        // Bubbles in like every other summoned surface. It can't use
        // `.popTransition()` — that needs a presenting container, and this
        // view's container is an `NSPanel` that AppKit has already put on
        // screen — so it drives the same curve from its own `onAppear`.
        .scaleEffect(shown ? 1 : Motion.popScale, anchor: .top)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(Motion.pop(reduceMotion: reduceMotion)) { shown = true }
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
    }

    /// Base fill plus a wash that fades out near the top. Flat fills are the
    /// difference between a panel that looks drawn and one that looks lit.
    private var surface: some View {
        shape
            .fill(Theme.overlay)
            .overlay(
                LinearGradient(
                    colors: [Theme.sheen, .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .clipShape(shape)
            )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.m) {
            // Wears the same state colour as the menu bar icon it hangs from,
            // so the panel reads as that icon opening rather than a separate
            // thing that happens to be nearby.
            AppMark(size: 15, tint: model.dominantTint)
            Text("Current")
                .typeStyle(Typo.heading)
                .foregroundStyle(Theme.text)
            Spacer(minLength: Space.m)
            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .iconButton(size: 26, glyph: 12)
            .help("Add a magnet link")
            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .iconButton(size: 26, glyph: 12)
            .help("Settings")
            Button(action: onOpenApp) {
                Image(systemName: "macwindow")
            }
            .iconButton(size: 26, glyph: 12)
            .help("Open the window")
        }
        .padding(.horizontal, Space.xl)
        .frame(height: 52)
    }

    // MARK: Summary

    /// The one card that answers "is anything happening?" without reading a
    /// list. The rates are the biggest type in the panel because they're what
    /// most opens are actually checking.
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: 0) {
                rate(symbol: "arrow.down", value: model.downloadRate)
                    .frame(maxWidth: .infinity)
                // A hairline between the two, short of full height. Two numbers
                // side by side with only whitespace between them read as one
                // phrase; a rule makes them two readings.
                Rectangle()
                    .fill(Theme.stroke)
                    .frame(width: Size.hairline, height: 22)
                rate(symbol: "arrow.up", value: model.uploadRate)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: Space.m) {
                Text(statusLine)
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Space.m)
                if model.totalCount > 0 {
                    Button(model.hasActive ? "Pause All" : "Resume All") {
                        model.hasActive ? onPauseAll() : onResumeAll()
                    }
                    .currentButton(.secondary, scale: .small)
                }
            }
        }
        .padding(Space.l)
        // A well, not a raised card. This sits *inside* the panel, and a second
        // raised surface stacked on the first is how a panel starts looking
        // like a pile of boxes.
        .insetCard(radius: Radius.l, fill: Theme.well)
        .padding(.horizontal, Space.l)
        .padding(.top, Space.l)
        .padding(.bottom, Space.m)
    }

    private func rate(symbol: String, value: Double) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                // Direction is what this glyph says, and it says it in grey.
                // Painting it accent would put a second colour beside a number
                // for no extra meaning.
                .foregroundStyle(Theme.textTertiary)
            Text(value > 1 ? ByteFormatting.rate(value) : "—")
                .typeStyle(Typo.title)
                .tabularNumerics()
                .numericTransition()
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, Space.m)
    }

    private var statusLine: String {
        var parts: [String] = []
        if model.downloadingCount > 0 { parts.append("\(model.downloadingCount) downloading") }
        if model.seedingCount > 0 { parts.append("\(model.seedingCount) seeding") }
        if parts.isEmpty {
            return model.totalCount == 0 ? "Nothing in your library yet" : "Everything is idle"
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Transfers

    @ViewBuilder
    private var transfers: some View {
        if model.rows.isEmpty {
            VStack(spacing: Space.s) {
                Text("No transfers")
                    .typeStyle(Typo.label)
                    .foregroundStyle(Theme.textSecondary)
                Text("Add a magnet link to get going.")
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .padding(.bottom, Space.s)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("TRANSFERS")
                    .typeStyle(Typo.overline)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Space.xl)
                    .padding(.top, Space.s)
                    .padding(.bottom, Space.s)

                ForEach(model.rows) { row in
                    StatusPanelRow(
                        row: row,
                        onTogglePause: { onTogglePause(row.id) },
                        onReveal: { onReveal(row.id) },
                        onOpen: { onOpenTorrent(row.id) }
                    )
                }

                if model.hiddenCount > 0 {
                    Button(action: onOpenApp) {
                        Text("\(model.hiddenCount) more in the app")
                            .typeStyle(Typo.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.xl)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, Space.s)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: Space.m) {
                Button(action: onOpenApp) {
                    HStack(spacing: Space.s) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Open Current")
                    }
                }
                .currentButton(.ghost, scale: .small)
                Spacer(minLength: Space.m)
                Button("Quit", action: onQuit)
                    .currentButton(.ghost, scale: .small)
            }
            .padding(.horizontal, Space.l)
            .frame(height: 46)
        }
        // Sits a shade darker than the panel so the actions read as a base the
        // content rests on rather than two more rows of it.
        .background(Theme.fillSubtle)
    }
}

// MARK: - Row

/// One transfer: what it is, how far along, and the two things you'd reach for
/// without opening the app.
private struct StatusPanelRow: View {
    let row: StatusPanelModel.Row
    var onTogglePause: () -> Void
    var onReveal: () -> Void
    var onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(row.name)
                    .typeStyle(Typo.label)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)

                ProgressTrack(
                    fraction: row.progress,
                    tint: row.tint,
                    reduceMotion: reduceMotion,
                    track: Theme.trackRaised
                )
                .frame(height: 5)

                // Grey, all of it. These are numbers, and numbers in this app
                // are never coloured — the row already says what it is with a
                // tinted bar. The percentage sits one step up the grey ramp
                // because it's the number you actually came to read.
                HStack(spacing: Space.s) {
                    Text(percentText)
                        .foregroundStyle(Theme.textSecondary)
                    Text(detailText)
                        .foregroundStyle(Theme.textTertiary)
                }
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .numericTransition()
                .lineLimit(1)
            }

            Button(action: onTogglePause) {
                Image(systemName: row.isPaused ? "play.fill" : "pause.fill")
            }
            .iconButton(size: 26, glyph: 11)
            .help(row.isPaused ? "Resume" : "Pause")

            Button(action: onReveal) {
                Image(systemName: "folder")
            }
            .iconButton(size: 26, glyph: 11)
            .opacity(isHovering ? 1 : 0)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, Space.l)
        .frame(height: StatusPanelMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(isHovering ? Theme.fillSubtle : .clear)
                .padding(.horizontal, Space.m)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.name)
    }

    private var percentText: String {
        "\(Int((row.progress * 100).rounded()))%"
    }

    private var detailText: String {
        var parts: [String] = []
        if row.isPaused {
            parts.append("Paused")
        } else if row.isSeeding {
            if row.uploadRate > 1 { parts.append(ByteFormatting.rate(row.uploadRate)) }
            parts.append("Seeding")
        } else {
            if row.downloadRate > 1 { parts.append(ByteFormatting.rate(row.downloadRate)) }
            if let eta = row.etaSeconds { parts.append("\(ByteFormatting.eta(eta)) left") }
        }
        return parts.isEmpty ? "" : "· " + parts.joined(separator: " · ")
    }
}

// MARK: - App mark

/// The app's mark, drawn in SwiftUI so the panel's header and the menu bar
/// icon are the same shape from the same description. `StatusItemController`
/// draws the `NSImage` version for the menu bar itself.
struct AppMark: View {
    var size: CGFloat = 15
    var tint: Color

    var body: some View {
        Canvas { context, canvasSize in
            let unit = canvasSize.width / 15
            let bars: [(width: CGFloat, y: CGFloat)] = [(15, 1), (10, 4.5), (5.5, 8)]
            for bar in bars {
                let rect = CGRect(
                    x: (15 - bar.width) / 2 * unit,
                    y: bar.y * unit,
                    width: bar.width * unit,
                    height: 2.2 * unit
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.1 * unit, style: .continuous),
                    with: .color(tint)
                )
            }
            let dot = CGRect(x: 6.2 * unit, y: 11.4 * unit, width: 2.6 * unit, height: 2.6 * unit)
            context.fill(Path(ellipseIn: dot), with: .color(tint))
        }
        .frame(width: size, height: size * (14.0 / 15.0))
        .accessibilityHidden(true)
    }
}
