import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CurrentCore

/// The library list.
///
/// Hand-rolled, because `List(selection:)` brought the system's zebra stripes,
/// its blue selection band and its inset-group chrome with it, and those are
/// three of the loudest stock-macOS signals in the app. What it also brought was
/// click / ⌘-click / ⇧-click / arrow keys for free, so all of that is
/// reimplemented here on top of `ListSelection` — which is pure and tested,
/// precisely because this is where off-by-one selection bugs live.
///
/// **The animation is keyed on identity, never on values.** `membership` is the
/// list of ids and nothing else. Key it on the snapshots instead and the list
/// animates once a second forever, which is both pointless and the exact
/// per-tick layout churn that has killed this app before.
struct LibraryList: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let torrents: [TorrentSnapshot]

    @FocusState private var isListFocused: Bool
    @State private var isDropTargeted = false

    private var membership: [TorrentID] { torrents.map(\.id) }

    /// Split into three stages on purpose. As one chain this exceeded the
    /// type-checker's budget and failed to compile — "unable to type-check this
    /// expression in reasonable time". Each stage below gives inference an
    /// anchor to work from.
    var body: some View {
        surface
            .modifier(ListKeyHandling(
                hasRows: !torrents.isEmpty,
                hasSelection: !store.selection.isEmpty,
                onMove: { delta, extending in
                    store.moveSelection(by: delta, extending: extending, visible: membership)
                },
                onToggle: { app.togglePauseSelected() },
                onReveal: { if let id = orderedSelection.first { app.revealInFinder(id) } },
                onClear: { store.clearSelection() },
                onRemove: { app.confirmRemoval(of: store.selection) }
            ))
            // Selection must never outlive the rows it names, or Pause and
            // Remove act on torrents that aren't on screen.
            .onChange(of: membership) { _, visible in
                store.pruneSelection(visible: visible)
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectAllRequested)) { _ in
                guard isListFocused else { return }
                store.selectAll(visible: membership)
            }
            // Takes the keyboard back when a covering surface closes. Without
            // this, opening settings or the palette and pressing Escape left
            // focus nowhere: the arrow keys stopped moving through the library
            // and there was no way to get it back except clicking a row.
            .onChange(of: app.isSettingsVisible) { _, visible in
                if !visible { isListFocused = true }
            }
            .onChange(of: app.isCommandPaletteVisible) { _, visible in
                if !visible { isListFocused = true }
            }
            .onChange(of: app.isAddMagnetSheetVisible) { _, visible in
                if !visible { isListFocused = true }
            }
            .onChange(of: app.showMagnetFilePicker) { _, visible in
                if !visible { isListFocused = true }
            }
    }

    private var surface: some View {
        scroller
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvasVeil)
            .overlay {
                if torrents.isEmpty {
                    SectionEmptyState(section: store.activeSection)
                }
            }
            .overlay {
                if isDropTargeted { dropHighlight }
            }
            // The empty state has always said "drop a torrent here" — until now
            // nothing in the window accepted one, and only the notch panel did.
            .onDrop(of: [.fileURL, .url, .text, .plainText], isTargeted: dropTarget) { providers in
                handleDrop(providers)
            }
            .focusable()
            // macOS draws a system focus ring around anything focusable, and on
            // a view this size that is a giant accent rectangle around the whole
            // pane. The list shows where the keyboard is with its own outline on
            // the focused *row* instead — see `LibraryRow.isFocused`.
            .focusEffectDisabled()
            .focused($isListFocused)
            // The list claims focus on launch. Left alone, SwiftUI hands it to
            // the first text field it finds — the search box in the chrome bar —
            // so the app opened with a focus ring glowing in the title bar and
            // the arrow keys doing nothing to the library.
            .onAppear { isListFocused = true }
            // Clicking empty space clears the selection and takes focus, so the
            // arrow keys have somewhere to start from.
            .contentShape(Rectangle())
            .onTapGesture {
                isListFocused = true
                store.clearSelection()
            }
    }

    private var scroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(torrents) { snapshot in
                        row(snapshot)
                            .id(snapshot.id)
                    }
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.m)
            }
            .scrollIndicators(.automatic)
            .animation(Motion.spring(reduceMotion: reduceMotion), value: membership)
            // Keeps the keyboard cursor on screen while arrowing. Anchored to
            // the middle rather than the edge so a long press of ↓ scrolls
            // smoothly instead of jumping a page at a time.
            .onChange(of: store.focusedRow) { _, id in
                guard let id else { return }
                withAnimation(Motion.spring(Motion.quick, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Rows

    /// A real `Button`, not a view with a tap gesture.
    ///
    /// The click and the press animation have to come from the same gesture. An
    /// `onTapGesture` plus a separate press-tracking drag looks identical and
    /// doesn't work — see `PressableStyle` for the full story.
    private func row(_ snapshot: TorrentSnapshot) -> some View {
        Button {
            isListFocused = true
            store.handleClick(gesture(), on: snapshot.id, visible: membership)
        } label: {
            LibraryRow(
                snapshot: snapshot,
                record: store.record(for: snapshot.id),
                failure: app.failures[snapshot.id],
                isSelected: store.selection.contains(snapshot.id),
                // Only worth outlining when there is a range to keep track of.
                // On a single selected row the fill already says where you are,
                // and a ring on top of it is just noise.
                isFocused: isListFocused && store.selection.count > 1 && store.focusedRow == snapshot.id
            )
        }
        .pressable(scale: Motion.pressScaleLarge)
        .contextMenu { RowContextMenu(snapshot: snapshot) }
        // Rows arrive and leave rather than popping. Insertion lifts slightly;
        // removal only fades, because something being taken away should get out
        // of the way instead of performing on the way out.
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -Motion.enterOffset)),
                    removal: .opacity
                )
        )
    }

    /// Which selection gesture a click means.
    ///
    /// Read straight off `NSEvent` rather than through SwiftUI's
    /// `TapGesture().modifiers(_:)`. Those need to be stacked as competing
    /// high-priority gestures to resolve correctly, and getting the priority
    /// order wrong silently turns ⌘-click back into a plain click — which looks
    /// like the selection being buggy rather than like a gesture conflict.
    private func gesture() -> ListSelection.Gesture {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) { return .extend }
        if flags.contains(.command) { return .toggle }
        return .replace
    }

    private var orderedSelection: [TorrentID] {
        membership.filter { store.selection.contains($0) }
    }

    // MARK: - Drop

    private var dropTarget: Binding<Bool> {
        Binding(
            get: { isDropTargeted },
            set: { targeted in
                withAnimation(Motion.spring(Motion.quick, reduceMotion: reduceMotion)) {
                    isDropTargeted = targeted
                }
            }
        )
    }

    /// An accent border inside the pane rather than a tinted wash over it. The
    /// wash hides the list you are dropping onto; the border says "here" and
    /// leaves the content readable.
    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .padding(Space.s)
            .background(Theme.accentSoft.opacity(0.5).padding(Space.s))
            .overlay {
                VStack(spacing: Space.m) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 26, weight: .light))
                    Text("Drop to add")
                        .typeStyle(Typo.label)
                }
                .foregroundStyle(Theme.accent)
            }
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    /// Loads each dropped item and hands whatever it parses to the app.
    ///
    /// Callback-style rather than `async`/`await`, and not by choice:
    /// `NSItemProvider` is not `Sendable`, so awaiting a load would mean sending
    /// the provider across an isolation boundary, which Swift 6 rejects. The
    /// values that come *back* — a `URL`, a `String` — are `Sendable`, so each
    /// completion just hops to the main actor with its result.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let environment = app
        var accepted = false

        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in Self.add(url: url, to: environment) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let text = (value as? NSString) as String? else { return }
                    Task { @MainActor in Self.add(text: text, to: environment) }
                }
            }
        }
        return accepted
    }

    @MainActor
    private static func add(url: URL, to app: AppEnvironment) {
        let parsed = url.isFileURL
            ? DropParser.parse(fileURLs: [url])
            : DropParser.parse(pasteboard: [], urls: [url])
        deliver(parsed, to: app)
    }

    @MainActor
    private static func add(text: String, to app: AppEnvironment) {
        deliver(DropParser.parse(pasteboard: [text]), to: app)
    }

    /// Saying so when a drop lands on nothing usable. Silently ignoring it
    /// leaves the user assuming the app is broken rather than that the thing
    /// they dragged wasn't a torrent.
    @MainActor
    private static func deliver(_ parsed: [DropParser.Parsed], to app: AppEnvironment) {
        guard !parsed.isEmpty else {
            app.toasts.show(
                .warning,
                title: "Nothing to add",
                message: "That didn't contain a magnet link or a .torrent file."
            )
            return
        }
        app.handleDroppedItems(parsed)
    }
}

// MARK: - Keyboard

/// Every key the library list answers to.
///
/// A `ViewModifier` rather than another dozen links in the list's own chain,
/// which is what pushed it past the type-checker's limit. It also puts the
/// keyboard contract in one readable place — the list draws its own rows now, so
/// this *is* the keyboard support, and AGENTS.md requires every mouse
/// interaction to have one.
private struct ListKeyHandling: ViewModifier {
    let hasRows: Bool
    let hasSelection: Bool
    let onMove: (Int, Bool) -> Void
    let onToggle: () -> Void
    let onReveal: () -> Void
    let onClear: () -> Void
    let onRemove: () -> Void

    func body(content: Content) -> some View {
        content
            // The `keys:` overload rather than the single-key one, because only
            // this form hands back a `KeyPress` — and the modifiers on it are
            // what tell ⇧↓ (extend the range) from ↓ (move to the next row).
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard hasRows else { return .ignored }
                onMove(press.key == .upArrow ? -1 : 1, press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.space) {
                guard hasSelection else { return .ignored }
                onToggle()
                return .handled
            }
            .onKeyPress(.return) {
                guard hasSelection else { return .ignored }
                onReveal()
                return .handled
            }
            .onKeyPress(.escape) {
                guard hasSelection else { return .ignored }
                onClear()
                return .handled
            }
            .onKeyPress(.delete) {
                guard hasSelection else { return .ignored }
                onRemove()
                return .handled
            }
    }
}

// MARK: - Context menu

struct RowContextMenu: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    let snapshot: TorrentSnapshot

    /// Right-clicking a row that isn't in the selection acts on that row alone,
    /// which is what every Mac list does. Acting on the invisible selection
    /// instead is how you pause the wrong thing.
    private var ids: Set<TorrentID> {
        store.selection.contains(snapshot.id) ? store.selection : [snapshot.id]
    }

    var body: some View {
        Group {
            Button(toggleLabel) { store.togglePause(for: ids) }

            Divider()

            Button("Reveal in Finder") { app.revealInFinder(snapshot.id) }

            Menu("Seed Policy") {
                ForEach(policyOptions, id: \.0) { policy, title in
                    Button(title) { store.setPolicy(policy, for: ids) }
                }
            }

            Button(snapshot.pinned ? "Unpin" : "Pin") {
                store.setPinned(!snapshot.pinned, for: ids)
            }

            Divider()

            Button("Remove…", role: .destructive) {
                app.confirmRemoval(of: ids)
            }
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
        ]
    }
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
                message: "Failed downloads and stuck magnets show up here."
            )
        case .readyToClean:
            EmptyStateView(
                symbol: "sparkles",
                title: "Nothing to clean",
                message: "Completed downloads that have met their seeding goals appear here."
            )
        case .seeding:
            EmptyStateView(
                symbol: "arrow.up.circle",
                title: "Nothing seeding",
                message: "Finished downloads share back automatically until they meet their goal."
            )
        case .completed:
            EmptyStateView(
                symbol: "checkmark.circle",
                title: "Nothing finished yet",
                message: "Completed downloads collect here."
            )
        default:
            EmptyStateView(
                symbol: "arrow.down.circle",
                title: "No downloads",
                message: "Drop a magnet link or a .torrent file anywhere in this window.",
                primaryTitle: "Add Magnet",
                primaryAction: { app.beginAddMagnet() },
                shortcutHint: "⌘N"
            )
        }
    }
}

extension Notification.Name {
    static let togglePauseRequested = Notification.Name("current.togglePause")
    static let revealRequested = Notification.Name("current.reveal")
    static let selectAllRequested = Notification.Name("current.selectAll")
}
