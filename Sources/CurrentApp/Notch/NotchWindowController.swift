import AppKit
import SwiftUI
import Combine
import CurrentCore

/// Owns the notch experience window: a borderless, non-activating panel
/// pinned to the camera housing of the built-in display.
///
/// The panel exists in one of several frame states; resizing animates with an
/// ease-out so the surface appears to grow out of the hardware. When idle it
/// shrinks to exactly the notch rectangle and draws nothing — the app never
/// decorates the notch just because it can.
@MainActor
final class NotchWindowController: ObservableObject {

    @Published var isDetailExpanded = false

    /// Mirrored engine/library state so the hosted SwiftUI surface never
    /// needs the full object graph (avoids an init-order cycle).
    struct FeaturedTorrent: Equatable {
        let id: TorrentID
        let name: String
        let progress: Double
        let downloadRate: Double
        let uploadRate: Double
        let etaSeconds: TimeInterval?
    }

    struct SelectionSummary: Equatable {
        let id: TorrentID
        let name: String
        let fileCount: Int
        let totalBytes: Int64
    }

    /// Whether there is a library worth opening the detail card for. The
    /// arithmetic lives in `LibraryActivity` (Core) because the menu bar needs
    /// the same numbers and exists on Macs that have no notch.
    @Published private(set) var summary: LibraryActivity?

    /// Active transfers the hover card lists, newest-downloading first. Capped
    /// at `expandedRowLimit` so a hundred-torrent library can't ask for a panel
    /// taller than the screen.
    @Published private(set) var activeDownloads: [FeaturedTorrent] = []

    /// How many rows the card shows before it needs a "more" toggle.
    static let collapsedRowLimit = 2
    /// The most it will ever show, expanded.
    static let expandedRowLimit = 5

    static let rowHeight: CGFloat = 52
    static let moreRowHeight: CGFloat = 26
    private static let cardInset: CGFloat = 16
    private static let hiddenHoverMargin: CGFloat = 10

    /// Row identities frozen at the moment the card opened.
    ///
    /// Without this the card resizes under a stationary pointer: which
    /// torrents count as "active" jitters every tick in normal operation, so
    /// the row count — and therefore the panel height — changed twice a
    /// second. Measured: the panel oscillated between 152pt and 176pt while
    /// the mouse sat still. Values inside the rows still update live; only the
    /// set of rows is pinned.
    private var pinnedRowIDs: [TorrentID]?

    /// Latest mirror for every torrent, so pinned rows keep updating even if a
    /// torrent stops being "active" while the card is open.
    private var mirrorsByID: [TorrentID: FeaturedTorrent] = [:]

    private var rowIDs: [TorrentID] {
        pinnedRowIDs ?? activeDownloads.map(\.id)
    }

    var visibleDownloads: [FeaturedTorrent] {
        let limit = isDetailExpanded ? Self.expandedRowLimit : Self.collapsedRowLimit
        return rowIDs.prefix(limit).compactMap { mirrorsByID[$0] }
    }

    var hiddenDownloadCount: Int {
        max(0, rowIDs.count - Self.collapsedRowLimit)
    }

    /// Height the card's content actually needs. The panel used to open at one
    /// fixed size no matter what was in it, so a single "download complete"
    /// badge sat in a mostly-empty black rectangle.
    private var cardContentHeight: CGFloat {
        switch flowStage {
        case .completed: return 66
        case .selecting: return 150
        case .starting: return 44
        case .resolving: return 96
        case .idle:
            let rows = max(visibleDownloads.count, 1)
            let more = hiddenDownloadCount > 0 ? Self.moreRowHeight : 0
            return CGFloat(rows) * Self.rowHeight + more + Self.cardInset
        }
    }
    @Published private(set) var featured: FeaturedTorrent?
    @Published private(set) var selectionSummary: SelectionSummary?
    @Published private(set) var flowStage: StageMirror = .idle

    enum StageMirror: Equatable {
        case idle
        case resolving(nameHint: String?, startedAt: Date)
        case selecting
        case starting
        case completed(name: String)
    }

    // Wired by AppEnvironment after construction.
    weak var app: AppEnvironment?
    var onPause: (TorrentID) -> Void = { _ in }
    var onReveal: (TorrentID) -> Void = { _ in }
    var onChooseFiles: () -> Void = {}
    var onConfirmSelection: (_ selectedBytes: Int64) -> Void = { _ in }
    var onCancelSelection: () -> Void = {}

    private var panel: NSPanel?
    private var hostingView: NotchContainerView?
    private var cancellables = Set<AnyCancellable>()

    private(set) var isAvailable = false
    private var geometry: NotchGeometry?
    private var currentFrame: CGRect = .zero
    private var hoverPoll: Timer?

    private let enabled: () -> Bool

    // Bound after AppEnvironment finishes constructing.
    weak var center: MagnetFlowCenter?
    weak var library: LibraryStore?

    struct NotchGeometry {
        let screen: NSScreen
        /// Screen coordinates of the physical notch.
        let notchRect: CGRect
    }

    init(enabled: @escaping () -> Bool) {
        self.enabled = enabled
        rebuildGeometry()
        observeScreens()
    }

    func bind(center: MagnetFlowCenter, library: LibraryStore) {
        self.center = center
        self.library = library

        center.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshVisibility()
                    self?.updateMirrors()
                }
            }
            .store(in: &cancellables)

        library.objectWillChange
            .throttle(for: .seconds(0.5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshVisibility()
                    self?.updateMirrors()
                }
            }
            .store(in: &cancellables)

        updateMirrors()
    }

    private func updateMirrors() {
        guard let library else { return }

        switch center?.stage {
        case .resolving(let hint, let startedAt):
            flowStage = .resolving(nameHint: hint, startedAt: startedAt)
        case .selecting:
            flowStage = .selecting
        case .starting:
            flowStage = .starting
        case .completed(let name):
            flowStage = .completed(name: name)
        case .idle, nil:
            flowStage = .idle
        }

        // Featured: the newest actively-downloading torrent, else any active one.
        let candidates = library.orderedIDs.compactMap { library.snapshot(for: $0) }
        let downloading = candidates.filter {
            if case .downloading = $0.state { return true }
            return false
        }
        let active = candidates.filter(\.state.isActive)
        if let pick = downloading.first ?? active.first {
            featured = FeaturedTorrent(
                id: pick.id,
                name: pick.name,
                progress: pick.progress,
                downloadRate: pick.downloadRate,
                uploadRate: pick.uploadRate,
                etaSeconds: pick.etaSeconds
            )
        } else {
            featured = nil
        }

        mirrorsByID = Dictionary(
            uniqueKeysWithValues: candidates.map {
                ($0.id, FeaturedTorrent(
                    id: $0.id,
                    name: $0.name,
                    progress: $0.progress,
                    downloadRate: $0.downloadRate,
                    uploadRate: $0.uploadRate,
                    etaSeconds: $0.etaSeconds
                ))
            }
        )

        // Everything the card can list: downloads first (what you're waiting
        // on), then other active transfers.
        let ordered = downloading + active.filter { candidate in
            !downloading.contains { $0.id == candidate.id }
        }
        activeDownloads = ordered.prefix(Self.expandedRowLimit).map {
            FeaturedTorrent(
                id: $0.id,
                name: $0.name,
                progress: $0.progress,
                downloadRate: $0.downloadRate,
                uploadRate: $0.uploadRate,
                etaSeconds: $0.etaSeconds
            )
        }

        // Recomputed on the controller's 2 Hz tick like every other mirror,
        // never per engine batch.
        summary = LibraryActivity.summarize(candidates)

        // Selection summary while a magnet resolves into a picker.
        if case .selecting(let id) = center?.stage,
           let metadata = library.metadataCache[id] {
            let name = metadata.displayName
            selectionSummary = SelectionSummary(
                id: id,
                name: name,
                fileCount: metadata.files.count,
                totalBytes: metadata.totalSize
            )
        } else {
            selectionSummary = nil
        }
    }

    // MARK: - Geometry

    private func rebuildGeometry() {
        guard let screen = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) else {
            geometry = nil
            isAvailable = false
            return
        }
        let left = screen.auxiliaryTopLeftArea!
        let right = screen.auxiliaryTopRightArea!
        let width = right.minX - left.maxX
        let height = max(left.height, 24)
        let notchRect = CGRect(
            x: left.maxX,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        geometry = NotchGeometry(screen: screen, notchRect: notchRect)
        notchHeight = height
        isAvailable = true
    }

    private func observeScreens() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAvailable = self.isAvailable
                self.rebuildGeometry()
                if wasAvailable || self.isAvailable {
                    self.installIfNeeded()
                    self.refreshVisibility()
                } else if self.panel == nil {
                    self.installIfNeeded()
                }
            }
        }
    }

    // MARK: - Panel lifecycle

    func installIfNeeded() {
        guard panel == nil, isAvailable else { return }

        let container = NotchContainerView()
        container.onHoverChanged = { [weak self] hovering in
            MainActor.assumeIsolated {
                self?.setHovered(hovering)
            }
        }

        let hosting = NSHostingView(rootView: NotchSurfaceView(controller: self))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.hostingView = container

        let panel = NotchPanel(
            contentRect: initialFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.controller = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = container
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()

        self.panel = panel
        applyFrame(animated: false)
    }

    private func initialFrame() -> NSRect {
        geometry.map { $0.notchRect } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    // MARK: - State → frame

    enum SurfaceState: Equatable {
        case hidden       // nothing drawn, exact notch footprint
        case pill         // compact activity strip hanging from the notch
        case card         // hover expansion or click detail
        case dropTarget   // enlarged during a drag session
    }

    @Published private(set) var surfaceState: SurfaceState = .hidden

    /// Height of the physical camera housing, republished when displays change.
    ///
    /// Anything drawn in the top `notchHeight` points of the panel sits behind
    /// aluminium: invisible on the actual display, but still present in the
    /// framebuffer — so it shows up perfectly in a screen capture. That
    /// asymmetry makes this very easy to get wrong and very confusing to debug,
    /// which is exactly what happened. Content must start below this.
    @Published private(set) var notchHeight: CGFloat = 32

    private func evaluateState() -> SurfaceState {
        guard let center, enabled(), isAvailable else { return .hidden }

        if center.isDropTarget { return .dropTarget }

        switch center.stage {
        case .selecting, .starting:
            return .card
        case .resolving:
            return center.isHovered ? .card : .pill
        case .completed:
            return .card
        case .idle:
            break
        }

        // Idle transfer activity shows NOTHING here. Collapsed, the panel is
        // exactly the notch footprint and draws nothing, so it is
        // indistinguishable from the bare camera housing — no strip, no bar,
        // nothing built on top of the hardware.
        //
        // The at-a-glance status lives in the menu bar item instead
        // (`StatusItemController`), which sits beside the notch in the real
        // menu bar and is visible on every Mac, notch or not. Note that content
        // cannot be drawn *inside* the notch: that strip is behind the housing,
        // so it is invisible on the display even though it appears in
        // screenshots.
        //
        // Hovering the notch opens the detail card. Hover still reaches us
        // while collapsed because `isInteractive` only gates hitTest (clicks),
        // not the tracking areas.
        // `summarize` returns nil for an empty library, so a non-nil summary
        // already means there is something to show.
        if summary != nil, center.isHovered {
            return .card
        }

        return .hidden
    }

    private var hasActivity: Bool {
        guard let library else { return false }
        return library.aggregateDownloadRate > 1 || library.aggregateUploadRate > 1
    }

    /// Read from the workspace rather than the SwiftUI environment: this is a
    /// controller, not a view, so there is no environment to read from.
    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func refreshVisibility() {
        installIfNeeded()
        let newState = evaluateState()
        if newState != surfaceState {
            withAnimation(Motion.spring(reduceMotion: prefersReducedMotion)) {
                surfaceState = newState
            }
        } else {
            surfaceState = newState
        }
        applyFrame(animated: true)
        hostingView?.isInteractive = newState != .hidden
    }

    private func targetFrame() -> NSRect {
        guard let geometry else { return .zero }
        let notch = geometry.notchRect
        let screenTop = geometry.screen.frame.maxY

        // Every height below is `notch.height + the space the content actually
        // needs`, because the first `notch.height` points are hidden behind the
        // camera housing. The pill used to be `notch.height + 12`, which left
        // 12pt for a line of text — so it rendered as a black bar with its
        // contents tucked invisibly under the housing.
        let frame: (width: CGFloat, height: CGFloat)
        switch surfaceState {
        case .hidden:
            // A few points taller than the notch. The housing is opaque and
            // the pointer is invisible behind it, so a hover target that is
            // exactly the notch means aiming at something you cannot see.
            // These extra points are fully transparent — nothing is drawn.
            frame = (notch.width, notch.height + Self.hiddenHoverMargin)
        case .pill:
            // Deliberately close to the notch's own width so it reads as the
            // housing bulging slightly, not as a bar hanging off it. Only 30pt
            // of it is below the housing and therefore actually visible.
            frame = (notch.width + 44, notch.height + 30)
        case .card:
            frame = (340, notch.height + cardContentHeight)
        case .dropTarget:
            frame = (380, notch.height + 130)
        }

        return CGRect(
            x: notch.midX - frame.width / 2,
            y: screenTop - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    private func applyFrame(animated: Bool) {
        guard let panel else { return }
        let target = targetFrame()
        guard target != panel.frame else {
            currentFrame = target
            return
        }
        currentFrame = target
        guard animated, !prefersReducedMotion else {
            panel.setFrame(target, display: false)
            return
        }
        // `animator()` is load-bearing: NSWindow.setFrame(display:animate:) ignores
        // this context's duration and timing entirely, blocks the main thread until
        // it finishes, and can't retarget if the state changes again mid-resize.
        // The animator proxy honours all three.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.standard
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        })
    }

    // MARK: - Hover

    private func setHovered(_ hovering: Bool) {
        guard center?.isHovered != hovering else { return }
        center?.isHovered = hovering
        if hovering {
            // Freeze which rows the card shows for as long as it is open.
            pinnedRowIDs = activeDownloads.map(\.id)
            startHoverPoll()
        } else {
            isDetailExpanded = false
            pinnedRowIDs = nil
            stopHoverPoll()
        }
        refreshVisibility()
    }

    /// Hover *exit* is detected by polling the pointer, not by `mouseExited`.
    ///
    /// Entering the panel resizes it, resizing changes the view's bounds,
    /// changing bounds rebuilds the tracking areas, and rebuilding them fires
    /// spurious enter/exit pairs. Acting on those made the card open and close
    /// under a stationary cursor. Polling the actual pointer position cannot
    /// be fooled by any of that.
    private func startHoverPoll() {
        stopHoverPoll()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                // Small slack so a pointer resting exactly on the edge, or a
                // frame mid-animation, doesn't count as having left.
                let zone = panel.frame.insetBy(dx: -6, dy: -6)
                if !zone.contains(NSEvent.mouseLocation) {
                    self.setHovered(false)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverPoll = timer
    }

    private func stopHoverPoll() {
        hoverPoll?.invalidate()
        hoverPoll = nil
    }

    // MARK: - Drop plumbing

    var onDroppedItems: (([DropParser.Parsed]) -> Void)?
}

/// Content view of the notch panel: hover tracking plus drag destination.
final class NotchContainerView: NSView {

    var onHoverChanged: ((Bool) -> Void)?
    /// When false the view forwards clicks through to whatever is underneath.
    var isInteractive = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    /// Deliberately empty. Exit is decided by the controller's pointer poll —
    /// see `startHoverPoll`. Resizing the panel rebuilds tracking areas and
    /// fires exits that never happened, and acting on them made the card
    /// flicker. Do not "restore" this.
    override func mouseExited(with event: NSEvent) {}

    /// Clicks pass through when there's nothing visible to interact with.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }

    // MARK: Drag destination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? [.copy] : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? [.copy] : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated {
            (window as? NotchPanel)?.controller?.center?.isDropTarget = false
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let controller = (window as? NotchPanel)?.controller else { return false }
            controller.center?.isDropTarget = false

            let pasteboard = sender.draggingPasteboard
            let urls = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
            let strings = (pasteboard.readObjects(forClasses: [NSString.self]) as? [String]) ?? []
            let parsed = DropParser.parse(pasteboard: strings, urls: urls)
            guard !parsed.isEmpty else { return false }
            controller.onDroppedItems?(parsed)
            return true
        }
    }

    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        let types = sender.draggingPasteboard.types ?? []
        return types.contains(.fileURL) || types.contains(.URL) || types.contains(.string)
    }
}

final class NotchPanel: NSPanel {
    weak var controller: NotchWindowController?
}
