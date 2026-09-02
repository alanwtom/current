import SwiftUI
import AppKit
import CurrentCore

/// The library list. Selection semantics are native macOS: click, ⌘-click,
/// ⇧-click range, arrow keys. Space toggles pause via the key catcher below.
struct TorrentListView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let torrents: [TorrentSnapshot]

    /// Identity only. The snapshots themselves change every engine tick
    /// (rates, progress, ETA); keying the animation on the whole array would
    /// animate the list once a second forever, which is both pointless and
    /// the exact per-tick layout churn that crashed this app before. Rows
    /// should only move when the *set* of rows changes.
    private var membership: [TorrentID] { torrents.map(\.id) }

    var body: some View {
        List(selection: $store.selection) {
            ForEach(torrents) { snapshot in
                TorrentRowView(
                    snapshot: snapshot,
                    record: store.record(for: snapshot.id),
                    failure: app.failures[snapshot.id]
                )
                .tag(snapshot.id)
                .contextMenu { RowContextMenu(snapshot: snapshot) }
            }
        }
        // Striping an empty list draws a dozen empty bands behind the "No
        // downloads" message, which reads as broken chrome rather than as an
        // empty state. Nothing to alternate, so don't.
        .listStyle(.inset(alternatesRowBackgrounds: !torrents.isEmpty))
        .animation(Motion.spring(reduceMotion: reduceMotion), value: membership)
        .overlay {
            if torrents.isEmpty {
                SectionEmptyState(section: store.activeSection)
            }
        }
        .background(TorrentKeyCatcher())
    }
}

// MARK: - Context menu

struct RowContextMenu: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    let snapshot: TorrentSnapshot

    private var ids: Set<TorrentID> {
        store.selection.contains(snapshot.id)
            ? store.selection
            : [snapshot.id]
    }

    var body: some View {
        Group {
            Button(toggleLabel) { store.togglePause(for: ids) }
                .keyboardShortcut(" ", modifiers: [])

            Divider()

            Button("Reveal in Finder") { app.revealInFinder(snapshot.id) }

            Menu("Seed Policy") {
                ForEach(policyOptions, id: \.0) { policy, title in
                    Button(title) {
                        store.setPolicy(policy, for: ids)
                    }
                }
            }

            Button(ids.contains { $0 == snapshot.id } && snapshot.pinned ? "Unpin" : "Pin") {
                store.setPinned(!snapshot.pinned, for: ids)
            }

            Divider()

            Button("Remove…", role: .destructive) {
                app.confirmRemoval(of: ids)
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private var toggleLabel: String {
        if case .paused = snapshot.state { return "Resume" }
        if case .failed = snapshot.state { return "Retry" }
        return "Pause"
    }

    private var policyOptions: [(SeedPolicy, String)] {
        [
            (.balanced, "Balanced — 1.0× and 24 hours"),
            (.helpful, "Helpful — keeps rare torrents alive"),
            (.temporary, "Temporary — then ready for cleanup"),
            (.archive, "Archive — seed forever"),
            (.custom(SeedGoal(targetRatio: 2.0, minimumSeedSeconds: 48 * 3600)), "Custom…"),
        ]
    }
}

// MARK: - Keyboard handling

/// Routes a few global keys when the list has focus. Text fields keep their
/// keys because we check the first responder first.
struct TorrentKeyCatcher: NSViewRepresentable {
    final class CatcherView: NSView {
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 49 { // space
                NotificationCenter.default.post(name: .togglePauseRequested, object: nil)
            } else if event.keyCode == 36 { // return
                NotificationCenter.default.post(name: .revealRequested, object: nil)
            } else {
                super.keyDown(with: event)
            }
        }

        override var acceptsFirstResponder: Bool { true }
    }

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension Notification.Name {
    static let togglePauseRequested = Notification.Name("current.togglePause")
    static let revealRequested = Notification.Name("current.reveal")
}

// MARK: - Empty states per section

struct SectionEmptyState: View {
    @EnvironmentObject private var app: AppEnvironment
    let section: SidebarSection

    var body: some View {
        switch section {
        case .attention:
            EmptyStateView(
                symbol: "checkmark.seal",
                title: "Nothing needs attention",
                message: "Failed downloads and stuck magnets will show up here."
            )
        case .readyToClean:
            EmptyStateView(
                symbol: "sparkles",
                title: "Nothing to clean",
                message: "Completed downloads that have met their seeding goals appear here."
            )
        default:
            EmptyStateView(
                symbol: "arrow.down.circle",
                title: "No downloads",
                message: "Drop a torrent here or add a magnet link.",
                primaryTitle: "Add Magnet",
                primaryAction: { app.beginAddMagnet() },
                shortcutHint: "⌘N"
            )
        }
    }
}
