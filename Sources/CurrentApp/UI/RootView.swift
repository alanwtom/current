import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CurrentCore

struct RootView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var flow: MagnetFlowCenter
    @Environment(\.openSettings) private var openSettingsAction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @FocusState private var isSearchFocused: Bool
    @AppStorage("inspector.visible") private var inspectorVisible = true
    @StateObject private var metrics = WindowMetrics()
    @State private var columns: NavigationSplitViewVisibility = .automatic

    private var filteredTorrents: [TorrentSnapshot] {
        if store.activeSection == .readyToClean {
            return app.cleanup.plan.candidates.map(\.snapshot)
        }
        return store.visibleTorrents
    }

    var body: some View {
        // The width is measured out here, *outside* the split view, so the
        // reading is the window's and not the content's. Measuring inside
        // would feed the decision back into itself: hide the sidebar, the
        // content gets wider, the threshold flips back, show it again.
        GeometryReader { proxy in
            splitView
                .onAppear { metrics.update(width: proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in
                    metrics.update(width: width)
                }
        }
        .environment(\.isCompactLayout, metrics.isCompact)
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(store: store)
                .environmentObject(app.sidebarCounts)
        } detail: {
            detailContent
                .frame(minWidth: metrics.isCompact ? 280 : 460)
        }
        // Shrunk far enough, the sidebar is the first thing to go — it costs
        // ~200pt and the sections are still reachable from the command
        // palette. Sections come back on their own when there is room again.
        .onChange(of: metrics.isCompact) { _, compact in
            withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
                columns = compact ? .detailOnly : .all
            }
        }
        .toolbar { toolbar }
        .inspector(isPresented: inspectorBinding) {
            if let snapshot = selectedSnapshot {
                InspectorView(snapshot: snapshot)
                    .inspectorColumnWidth(min: 300, ideal: 320, max: 400)
            } else {
                EmptyView()
            }
        }
        .overlay(alignment: .top) {
            if !flow.usesNotchSurface {
                MagnetFlowOverlayView()
            }
        }
        .sheet(isPresented: $app.isAddMagnetSheetVisible) {
            AddMagnetSheet()
        }
        .sheet(isPresented: $app.showMagnetFilePicker) {
            if case .selecting(let id) = flow.stage,
               let metadata = store.metadataCache[id] {
                MagnetSelectionSheet(metadata: metadata)
            }
        }
        .confirmationDialog(
            removalTitle,
            isPresented: removalBinding,
            titleVisibility: .visible
        ) {
            Button("Move Files to Trash", role: .destructive) {
                Task { await app.removePending(deleteFiles: true) }
            }
            Button("Remove from Library (Keep Files)") {
                Task { await app.removePending(deleteFiles: false) }
            }
            Button("Cancel", role: .cancel) {
                app.pendingRemoval = []
            }
        } message: {
            Text("Files moved to Trash can be restored — removing is always reversible.")
        }
        .overlay {
            if app.isCommandPaletteVisible {
                CommandPalette(
                    isVisible: $app.isCommandPaletteVisible,
                    commands: commands
                )
                .zIndex(10)
            }
        }
        .overlay {
            ToastsOverlay()
                .zIndex(20)
        }
        .onAppear(perform: setupOnce)
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
    }

    // MARK: - Detail content

    @ViewBuilder
    private var detailContent: some View {
        TorrentListView(torrents: filteredTorrents)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Add Magnet Link…") { app.beginAddMagnet() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Torrent File…") { pickTorrentFile() }
                    .keyboardShortcut("o", modifiers: .command)
            } label: {
                Image(systemName: "plus")
            }
            .help("Add torrent")

            Button {
                app.isCommandPaletteVisible.toggle()
            } label: {
                Image(systemName: "command")
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("Command palette ⌘K")

            Toggle(isOn: $inspectorVisible) {
                Image(systemName: "sidebar.trailing")
            }
            .help("Toggle inspector")

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
                TextField("Search", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    // 170pt of search is most of a 380pt window; it gives back
                    // the space rather than pushing everything else into the
                    // toolbar's overflow menu.
                    .frame(width: metrics.isCompact ? 90 : 170)
                    .focused($isSearchFocused)
                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
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

    private var inspectorBinding: Binding<Bool> {
        Binding(
            // Forced shut in compact: at 380pt wide a 300pt inspector would
            // leave nothing for the list it is describing.
            get: { inspectorVisible && !store.selection.isEmpty && !metrics.isCompact },
            set: { inspectorVisible = $0 }
        )
    }

    private var removalTitle: String {
        let count = app.pendingRemoval.count
        return count <= 1 ? "Remove this download?" : "Remove \(count) downloads?"
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { !app.pendingRemoval.isEmpty },
            set: { if !$0 { app.pendingRemoval = [] } }
        )
    }

    // MARK: - Commands for the palette

    private var commands: [CommandPalette.Command] {
        [
            CommandPalette.Command("Add Magnet Link…", shortcutHint: "⌘N") {
                app.beginAddMagnet()
            },
            CommandPalette.Command("Open Torrent File…", shortcutHint: "⌘O") {
                pickTorrentFile()
            },
            CommandPalette.Command(store.selection.isEmpty == false && areSelectedPaused ? "Resume Selected" : "Pause Selected", shortcutHint: "Space") {
                app.togglePauseSelected()
            },
            CommandPalette.Command("Pause All", shortcutHint: "⇧⌘P") { app.pauseAll() },
            CommandPalette.Command("Resume All", shortcutHint: "⇧⌘R") { app.resumeAll() },
            CommandPalette.Command("Show All") { store.activeSection = .all },
            CommandPalette.Command("Show Downloading") { store.activeSection = .downloading },
            CommandPalette.Command("Show Seeding") { store.activeSection = .seeding },
            CommandPalette.Command("Clean Eligible Downloads…", shortcutHint: "⇧⌘C") {
                Task { await app.cleanEligibleNow() }
            },
            CommandPalette.Command("Reveal Selected in Finder") {
                if let id = store.selection.first { app.revealInFinder(id) }
            },
            CommandPalette.Command("Change Seed Policy to Balanced") {
                store.setPolicy(.balanced, for: store.selection)
            },
            CommandPalette.Command("Change Seed Policy to Helpful") {
                store.setPolicy(.helpful, for: store.selection)
            },
            CommandPalette.Command("Change Seed Policy to Temporary") {
                store.setPolicy(.temporary, for: store.selection)
            },
            CommandPalette.Command("Change Seed Policy to Archive") {
                store.setPolicy(.archive, for: store.selection)
            },
            CommandPalette.Command("Open Settings…", shortcutHint: "⌘,") {
                app.openSettings(tab: .general)
            },
        ]
    }

    private var areSelectedPaused: Bool {
        store.selection.allSatisfy { id in
            store.snapshot(for: id)?.state.isPaused ?? false
        }
    }

    // MARK: - Setup & file picking

    private func setupOnce() {
        app.requestOpenSettings = { openSettingsAction() }
        Task { await app.finishSetup() }
    }

    private func pickTorrentFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if #available(macOS 14.0, *) {
            if let type = UTType(filenameExtension: "torrent") {
                panel.allowedContentTypes = [type]
            }
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            Task { await app.addTorrentFile(at: url) }
        }
    }
}

extension Notification.Name {
    static let focusSearchRequested = Notification.Name("current.focusSearch")
}

// MARK: - Add magnet sheet

struct AddMagnetSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var validationError: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Magnet Link")
                .font(.headline)

            TextField("magnet:?xt=urn:btih:…", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .focused($isFocused)
                .onSubmit(add)

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(SemanticColor.failure)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedURI == nil && !looksLikePlainTextWithMagnet)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isFocused = true }
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
            dismiss()
        } else if let found = DropParser.magnets(in: text).first {
            Task { await app.addMagnet(found) }
            dismiss()
        } else {
            validationError = "That doesn't look like a magnet link."
        }
    }
}
