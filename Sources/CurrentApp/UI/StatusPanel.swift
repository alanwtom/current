import SwiftUI
import AppKit
import CurrentCore

// MARK: - Metrics

enum StatusPanelMetrics {
    /// Narrow on purpose. This hangs off the menu bar over whatever app you
    /// were using, so it has to read as a panel belonging to the menu bar
    /// rather than a second window that turned up.
    static let width: CGFloat = 324
    /// A row's fixed height. Fixed for the usual reason — see the layout-churn
    /// section of AGENTS.md — but also because the panel's window frame is set
    /// once when it opens, and a row that grew would be clipped by it.
    static let rowHeight: CGFloat = 54
    /// The most transfers listed before the rest become a "+N more" line. Five
    /// is where the panel stops being glanceable and starts being the library.
    static let maxRows = 5
    /// Gap between the menu bar and the top of the panel.
    static let menuBarGap: CGFloat = 6
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

    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            header
            summaryCard
            transfers
            footer
        }
        .frame(width: StatusPanelMetrics.width)
        .background(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .fill(Theme.overlay)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
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

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.m) {
            AppMark(size: 15, tint: Theme.accent)
            Text("Current")
                .typeStyle(Typo.heading)
                .foregroundStyle(Theme.text)
            Spacer(minLength: Space.m)
            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .iconButton(size: 24, glyph: 11)
            .help("Add a magnet link")
            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .iconButton(size: 24, glyph: 11)
            .help("Settings")
            Button(action: onOpenApp) {
                Image(systemName: "macwindow")
            }
            .iconButton(size: 24, glyph: 11)
            .help("Open the window")
        }
        .padding(.horizontal, Space.xl)
        .frame(height: 46)
    }

    // MARK: Summary

    /// The one card that answers "is anything happening?" without reading a
    /// list. The rates are the biggest type in the panel because they're what
    /// most opens are actually checking.
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.xxl) {
                rate(symbol: "arrow.down", value: model.downloadRate)
                rate(symbol: "arrow.up", value: model.uploadRate)
                Spacer(minLength: 0)
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
        .background(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .fill(Theme.fillSubtle)
        )
        .padding(.horizontal, Space.l)
        .padding(.bottom, Space.l)
    }

    private func rate(symbol: String, value: Double) -> some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
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
                Button("Open Current", action: onOpenApp)
                    .currentButton(.ghost, scale: .small)
                Spacer(minLength: Space.m)
                Button("Quit", action: onQuit)
                    .currentButton(.ghost, scale: .small)
            }
            .padding(.horizontal, Space.l)
            .frame(height: 40)
        }
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

                ProgressTrack(fraction: row.progress, tint: row.tint, reduceMotion: reduceMotion)
                    .frame(height: 3)

                // Grey, all of it. These are numbers, and numbers in this app
                // are never coloured — the row already says what it is with a
                // tinted bar.
                Text(meta)
                    .typeStyle(Typo.caption)
                    .tabularNumerics()
                    .numericTransition()
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }

            Button(action: onTogglePause) {
                Image(systemName: row.isPaused ? "play.fill" : "pause.fill")
            }
            .iconButton(size: 24, glyph: 10)
            .help(row.isPaused ? "Resume" : "Pause")

            Button(action: onReveal) {
                Image(systemName: "folder")
            }
            .iconButton(size: 24, glyph: 10)
            .opacity(isHovering ? 1 : 0)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, Space.xl)
        .frame(height: StatusPanelMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
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

    private var meta: String {
        var parts: [String] = ["\(Int((row.progress * 100).rounded()))%"]
        if row.isPaused {
            parts.append("Paused")
        } else if row.isSeeding {
            if row.uploadRate > 1 { parts.append(ByteFormatting.rate(row.uploadRate)) }
            parts.append("Seeding")
        } else {
            if row.downloadRate > 1 { parts.append(ByteFormatting.rate(row.downloadRate)) }
            if let eta = row.etaSeconds { parts.append("\(ByteFormatting.eta(eta)) left") }
        }
        return parts.joined(separator: " · ")
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
