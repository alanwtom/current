import SwiftUI
import AppKit
import CurrentCore

/// The window's whole layout, owned by the app.
///
/// This replaces `NavigationSplitView` + `.toolbar` + `.inspector`. All three
/// were doing their jobs; the problem is that they are the jobs that make an app
/// look like macOS drew it, and none of them can be restyled far enough to stop.
///
/// There is a second, less obvious payoff. `NavigationSplitView` negotiates its
/// column widths with AppKit, and *that negotiation* is what took this app down
/// twice — a sidebar whose content changed on every engine tick made the window
/// re-measure once a second, forever, until AppKit hit its constraint-pass limit
/// and trapped. Here the columns are plain `frame(width:)` calls driven by app
/// state, so a width only ever changes because the user asked for it.
///
/// The rules that still apply, and are easy to undo by accident:
///
/// - Animate on **identity, not values** (`LibraryList`).
/// - Live engine data reaches the chrome through a coalesced model
///   (`ActivityModel`, `SidebarCounts`), never by observing `LibraryStore`.
/// - Any change in here gets a 3-minute soak against `-simulate`, checking
///   `~/Library/Logs/DiagnosticReports/` for new `Current-*.ips` files.
struct AppShell: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var flow: MagnetFlowCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var metrics = WindowMetrics()

    @AppStorage("chrome.sidebarVisible") private var isSidebarVisible = true
    @AppStorage("chrome.inspectorVisible") private var isInspectorVisible = true
    // Stored as `Double` because that is what `@AppStorage` supports; the
    // `Chrome` tokens are `CGFloat`, so the two meet at the frame.
    @AppStorage("chrome.sidebarWidth") private var sidebarWidth = Double(Chrome.sidebarWidth)
    @AppStorage("chrome.inspectorWidth") private var inspectorWidth = Double(Chrome.inspectorWidth)

    @FocusState private var isSearchFocused: Bool

    private var filteredTorrents: [TorrentSnapshot] {
        if store.activeSection == .readyToClean {
            return app.cleanup.plan.candidates.map(\.snapshot)
        }
        return store.visibleTorrents
    }

    /// The inspector needs a selected torrent to describe, and needs the window
    /// to be wide enough to afford it — at 380pt a 320pt panel would leave
    /// nothing for the list it is describing.
    private var showsInspector: Bool {
        isInspectorVisible && selectedSnapshot != nil && !metrics.isCompact
    }

    private var showsSidebar: Bool {
        isSidebarVisible && !metrics.isCompact
    }

    var body: some View {
        // Measured out here, outside the columns, so the reading is the
        // window's and not the content's. Measuring inside would feed the
        // decision back into itself: hide the sidebar, the content gets wider,
        // the threshold flips back, show it again.
        GeometryReader { proxy in
            content(in: proxy.size)
                // Handed to the modal surfaces so each one can size itself
                // against the window instead of assuming it fits. See
                // `WindowLayout` for what that assumption used to cost.
                .environment(\.windowSize, proxy.size)
                .onAppear { metrics.update(width: proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in
                    metrics.update(width: width)
                }
        }
        .environment(\.isCompactLayout, metrics.isCompact)
        // Underneath everything, including the chrome bar's own veil.
        .background(WindowBlur().ignoresSafeArea())
        .background(
            WindowChrome(shouldClose: { proceed in
                // Nothing in flight — let it go without a word.
                guard app.unfinishedCount > 0 else { return true }
                app.pendingWindowClose = proceed
                return false
            })
            .frame(width: 0, height: 0)
        )
        .environmentObject(app.activity)
        .environmentObject(app.sidebarCounts)
    }

    private func content(in windowSize: CGSize) -> some View {
        let columns = WindowLayout.columns(
            windowWidth: windowSize.width,
            sidebar: CGFloat(sidebarWidth),
            inspector: CGFloat(inspectorWidth),
            showsSidebar: showsSidebar,
            showsInspector: showsInspector,
            minimumContent: Chrome.contentMinWidth,
            minimumSidebar: Chrome.sidebarMinWidth,
            minimumInspector: Chrome.inspectorMinWidth
        )

        return VStack(spacing: 0) {
            ChromeBar(
                isSidebarVisible: $isSidebarVisible,
                isInspectorVisible: $isInspectorVisible,
                searchFocus: $isSearchFocused
            )

            HStack(spacing: 0) {
                sidebarColumn(width: columns.sidebar)
                contentColumn
                inspectorColumn(width: columns.inspector)
            }
        }
        // Deliberately no background here. The chrome bar, sidebar, list and
        // inspector each paint their own, and an opaque fill behind them would
        // sit between the list's glass and the blur — so the one translucent
        // surface in the app would show this grey instead of the desktop.
        // Reclaims the title bar strip so the chrome bar starts at the very top
        // of the window and its controls land on the same line as the three
        // window buttons. Without this SwiftUI keeps a ~28pt safe area up there
        // and the bar sits underneath it, leaving the buttons stranded in an
        // empty band of their own.
        .ignoresSafeArea(.container, edges: .top)
        // Where a clicked magnet link reports in, and where it asks which files
        // to take. It used to be conditional — the notch panel had it on Macs
        // with a camera housing — so this same card was only ever seen by some
        // people, on some machines. It is now the only presentation.
        .overlay(alignment: .top) {
            MagnetFlowOverlayView()
                .padding(.top, Chrome.barHeight + Space.m)
        }
        // Every covering surface below is wrapped in a `ZStack` carrying
        // `Motion.pop(presenting:)`. That wrapper is what makes them bubble:
        // each surface describes its own entrance with `.popTransition()`, but a
        // transition only runs if the state change that triggered it was
        // animated — and none of these are set from inside `withAnimation`. They
        // come from a menu item, a keyboard shortcut, or an AppKit callback. Miss
        // the wrapper and the surface appears fully formed.
        .overlay {
            ZStack {
                if app.isCommandPaletteVisible {
                    CommandPalette(
                        isVisible: $app.isCommandPaletteVisible,
                        commands: commands
                    )
                }
            }
            .animation(
                Motion.pop(presenting: app.isCommandPaletteVisible, reduceMotion: reduceMotion),
                value: app.isCommandPaletteVisible
            )
            .zIndex(10)
        }
        .overlay {
            ZStack {
                if app.isSettingsVisible {
                    SettingsSurface()
                }
            }
            .animation(
                Motion.pop(presenting: app.isSettingsVisible, reduceMotion: reduceMotion),
                value: app.isSettingsVisible
            )
            .zIndex(15)
        }
        .overlay {
            ToastsOverlay()
                .zIndex(20)
        }
        // Above everything, including toasts: the first thing a launch shows
        // shouldn't be a notification landing on top of the logo.
        .overlay {
            if app.isIntroPlaying {
                LaunchIntro { app.isIntroPlaying = false }
                    .zIndex(30)
            }
        }
        // Was a `.sheet`, which is why the plus button used to drop a card out of
        // the title bar. See `ModalSurface`.
        .modalSurface(isPresented: $app.isAddMagnetSheetVisible) {
            AddMagnetSheet(close: { app.isAddMagnetSheetVisible = false })
        }
        // Clicking away only closes the picker — the flow stays in `.selecting`,
        // so the summary card is still there offering Download. The Cancel
        // button is the destructive one: it removes the torrent you just pasted,
        // and a stray click outside a panel shouldn't be able to do that.
        .modalSurface(isPresented: $app.showMagnetFilePicker) {
            if case .selecting(let id) = flow.stage,
               let metadata = store.metadataCache[id] {
                MagnetSelectionSheet(
                    metadata: metadata,
                    close: { app.showMagnetFilePicker = false }
                )
            }
        }
        // The app's own dialog, not `.confirmationDialog` — that drew an AppKit
        // sheet, which was the last piece of stock chrome left in the window.
        .overlay {
            ZStack {
                if !app.pendingRemoval.isEmpty {
                    ConfirmDialog(
                        title: removalTitle,
                        message: "Files moved to Trash can be restored — removing is always reversible.",
                        confirmTitle: "Move to Trash",
                        confirmIsDestructive: true,
                        alternateTitle: "Keep Files",
                        onConfirm: { Task { await app.removePending(deleteFiles: true) } },
                        onAlternate: { Task { await app.removePending(deleteFiles: false) } },
                        onCancel: { app.pendingRemoval = [] }
                    )
                }
            }
            .animation(
                Motion.pop(presenting: !app.pendingRemoval.isEmpty, reduceMotion: reduceMotion),
                value: app.pendingRemoval.isEmpty
            )
            .zIndex(25)
        }
        .overlay {
            ZStack {
                if let proceed = app.pendingWindowClose {
                    ConfirmDialog(
                        title: "Close the window?",
                        message: closeMessage,
                        confirmTitle: "Close",
                        onConfirm: {
                            app.pendingWindowClose = nil
                            proceed()
                        },
                        onCancel: { app.pendingWindowClose = nil }
                    )
                }
            }
            .animation(
                Motion.pop(presenting: app.pendingWindowClose != nil, reduceMotion: reduceMotion),
                value: app.pendingWindowClose == nil
            )
            .zIndex(26)
        }
        .onAppear { Task { await app.finishSetup() } }
        .onReceive(NotificationCenter.default.publisher(for: .togglePauseRequested)) { _ in
            guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
            app.togglePauseSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .revealRequested)) { _ in
            if let id = store.selection.first { app.revealInFinder(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchRequested)) { _ in
            isSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebarRequested)) { _ in
            withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
                isSidebarVisible.toggle()
            }
        }
    }

    // MARK: - Columns

    /// Collapses by animating its width to zero rather than by leaving the
    /// hierarchy.
    ///
    /// A `.transition(.move(edge: .leading))` looks right in isolation and wrong
    /// here: the row reclaims the space the instant the view is removed, so the
    /// sidebar slides out across content that has already finished moving. An
    /// animated width keeps the two in step.
    ///
    /// The width is resolved by `WindowLayout.columns`, not read straight from
    /// the stored preference — in a narrow window the preference is a request
    /// the window can't grant.
    private func sidebarColumn(width: CGFloat) -> some View {
        SidebarView(
            section: store.activeSection,
            onSelect: { next in
                withAnimation(Motion.spring(Motion.quick, reduceMotion: reduceMotion)) {
                    store.activeSection = next
                }
            }
        )
        .equatable()
        .frame(width: width)
        .opacity(showsSidebar ? 1 : 0)
        .clipped()
    }

    /// The library, set into the window's frame rather than butted up against
    /// the panels either side of it.
    ///
    /// The two seams are overlays on this column's own gutter, so they cost the
    /// row no width and can't push the pane around while they animate. Each one
    /// covers exactly the gap it lives in.
    private var contentColumn: some View {
        LibraryList(torrents: filteredTorrents)
            .insetPane()
            .overlay(alignment: .leading) {
                if showsSidebar {
                    ColumnResizer(
                        width: $sidebarWidth,
                        range: Double(Chrome.sidebarMinWidth)...Double(Chrome.sidebarMaxWidth),
                        edge: .leading
                    )
                }
            }
            .overlay(alignment: .trailing) {
                if showsInspector {
                    ColumnResizer(
                        width: $inspectorWidth,
                        range: Double(Chrome.inspectorMinWidth)...Double(Chrome.inspectorMaxWidth),
                        edge: .trailing
                    )
                }
            }
    }

    @ViewBuilder
    private func inspectorColumn(width: CGFloat) -> some View {
        if let snapshot = selectedSnapshot {
            InspectorPanel(snapshot: snapshot)
                .frame(width: width)
                .opacity(showsInspector ? 1 : 0)
                .clipped()
        }
    }

    // MARK: - Selection plumbing

    private var selectedSnapshot: TorrentSnapshot? {
        guard let id = sortedSelection.first else { return nil }
        return store.snapshot(for: id)
    }

    private var sortedSelection: [TorrentID] {
        store.orderedIDs.filter { store.selection.contains($0) }
    }

    private var removalTitle: String {
        let count = app.pendingRemoval.count
        return count <= 1 ? "Remove this download?" : "Remove \(count) downloads?"
    }

    /// Truthful about what closing actually does. The app keeps running in the
    /// menu bar, so this is a heads-up rather than a warning — telling someone
    /// their downloads are about to stop when they aren't would be worse than
    /// not asking at all.
    private var closeMessage: String {
        let count = app.unfinishedCount
        let noun = count == 1 ? "download is" : "downloads are"
        return "\(count) \(noun) still running. They'll keep going in the menu bar — reopen the window from there any time."
    }

    // MARK: - Commands for the palette

    private var commands: [CommandPalette.Command] {
        [
            CommandPalette.Command("Add Magnet Link…", symbol: "link", shortcutHint: "⌘N") {
                app.beginAddMagnet()
            },
            CommandPalette.Command("Open Torrent File…", symbol: "doc", shortcutHint: "⌘O") {
                app.pickTorrentFile()
            },
            CommandPalette.Command(
                areSelectedPaused ? "Resume Selected" : "Pause Selected",
                symbol: areSelectedPaused ? "play" : "pause",
                shortcutHint: "Space"
            ) {
                app.togglePauseSelected()
            },
            CommandPalette.Command("Pause All", symbol: "pause.circle", shortcutHint: "⇧⌘P") { app.pauseAll() },
            CommandPalette.Command("Resume All", symbol: "play.circle", shortcutHint: "⇧⌘R") { app.resumeAll() },
            CommandPalette.Command("Show All", symbol: "square.grid.2x2") { store.activeSection = .all },
            CommandPalette.Command("Show Downloading", symbol: "arrow.down.circle") { store.activeSection = .downloading },
            CommandPalette.Command("Show Seeding", symbol: "arrow.up.circle") { store.activeSection = .seeding },
            CommandPalette.Command("Clean Eligible Downloads…", symbol: "sparkles", shortcutHint: "⇧⌘C") {
                Task { await app.cleanEligibleNow() }
            },
            CommandPalette.Command("Reveal Selected in Finder", symbol: "folder") {
                if let id = store.selection.first { app.revealInFinder(id) }
            },
            CommandPalette.Command("Change Seed Policy to Balanced", symbol: "scale.3d") {
                store.setPolicy(.balanced, for: store.selection)
            },
            CommandPalette.Command("Change Seed Policy to Helpful", symbol: "hand.raised") {
                store.setPolicy(.helpful, for: store.selection)
            },
            CommandPalette.Command("Change Seed Policy to Temporary", symbol: "clock") {
                store.setPolicy(.temporary, for: store.selection)
            },
            CommandPalette.Command("Change Seed Policy to Archive", symbol: "archivebox") {
                store.setPolicy(.archive, for: store.selection)
            },
            CommandPalette.Command("Appearance…", symbol: "circle.lefthalf.filled") {
                app.openSettings(tab: .appearance)
            },
            CommandPalette.Command("Settings…", symbol: "gearshape", shortcutHint: "⌘,") {
                app.openSettings(tab: .general)
            },
        ]
    }

    private var areSelectedPaused: Bool {
        !store.selection.isEmpty && store.selection.allSatisfy { id in
            store.snapshot(for: id)?.state.isPaused ?? false
        }
    }
}

// MARK: - Column resizer

/// The draggable seam between two columns.
///
/// **It draws nothing at rest, and that is the point.** The columns are already
/// told apart by the content pane's curve and its change of tone; a permanent
/// line on top of that says the same thing a second time, in the one visual
/// idiom that instantly dates a Mac window. What used to sit here was a 1pt
/// hairline with 4pt of unpainted padding either side — and because the shell
/// paints no background, that padding showed the blurred desktop, so each seam
/// was a bright strip rather than the discreet line it was supposed to be.
///
/// The grab area is the full width of the gutter, so the target is generous
/// without anything having to be drawn to advertise it. A neutral grip fades in
/// under the cursor and turns accent while you drag, because accent in this app
/// means "this is happening".
private struct ColumnResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let edge: HorizontalEdge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var startWidth: Double?

    var body: some View {
        Capsule(style: .continuous)
            .fill(isDragging ? Theme.accent : Theme.strokeStrong)
            .frame(width: Chrome.seamGrip)
            // Stops short of the top and bottom by the gutter's own depth, so
            // the grip runs the height of the pane it resizes rather than the
            // height of the window.
            .padding(.vertical, Chrome.contentInset)
            .opacity(isHovering || isDragging ? 1 : 0)
            .animation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion), value: isDragging)
            .frame(width: Chrome.seamWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion)) {
                    isHovering = hovering
                }
                // The system's own column-resize cursor, because inventing one
                // would be worse and people already know this arrow.
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // Anchored to where the drag started rather than
                        // accumulating deltas, so the seam tracks the cursor
                        // exactly instead of drifting away from it.
                        let base = startWidth ?? width
                        if startWidth == nil { startWidth = width; isDragging = true }
                        let delta = Double(edge == .leading ? value.translation.width : -value.translation.width)
                        width = min(max(base + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        startWidth = nil
                        withAnimation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion)) {
                            isDragging = false
                        }
                    }
            )
            .accessibilityHidden(true)
    }
}

extension Notification.Name {
    static let focusSearchRequested = Notification.Name("current.focusSearch")
    static let toggleSidebarRequested = Notification.Name("current.toggleSidebar")
}

// MARK: - Add magnet sheet

/// The card behind the plus button.
///
/// Presented by `modalSurface`, not `.sheet` — so it takes a `close` closure
/// rather than reading `\.dismiss`, which does nothing outside a real
/// presentation. It also has to claim the keyboard itself: an overlay doesn't
/// get first responder handed to it the way a sheet does, so without
/// `autofocus` the field would open empty and unfocused with the library list
/// still eating the arrow keys behind the scrim.
struct AddMagnetSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    let close: () -> Void
    @State private var text = ""
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Add Magnet Link")
                    .typeStyle(Typo.title)
                    .foregroundStyle(Theme.text)
                Text("Paste a magnet link, or any text containing one.")
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            CurrentField(
                "magnet:?xt=urn:btih:…",
                text: $text,
                scale: .large,
                monospaced: true,
                autofocus: true,
                onSubmit: add
            )

            if let validationError {
                Callout(symbol: "exclamationmark.circle.fill", tint: Theme.failure) {
                    Text(validationError)
                        .typeStyle(Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: Space.m) {
                Spacer()
                Button("Cancel") { close() }
                    .currentButton(.ghost)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .currentButton(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedURI == nil && !looksLikePlainTextWithMagnet)
            }
        }
        .padding(Space.xxl)
        .modalSize(width: 460)
        // No background of its own any more: `ModalSurface` draws the card, so
        // this gets the same fill, edge, highlight and shadow as every other
        // floating surface instead of a flat rectangle in an AppKit sheet.
        .animation(Motion.spring(Motion.quick), value: validationError)
    }

    private var trimmedURI: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("magnet:") ? trimmed : nil
    }

    private var looksLikePlainTextWithMagnet: Bool {
        !DropParser.magnets(in: text).isEmpty
    }

    private func add() {
        if let uri = trimmedURI {
            Task { await app.addMagnet(uri) }
            close()
        } else if let found = DropParser.magnets(in: text).first {
            Task { await app.addMagnet(found) }
            close()
        } else {
            validationError = "That doesn't look like a magnet link."
        }
    }
}
