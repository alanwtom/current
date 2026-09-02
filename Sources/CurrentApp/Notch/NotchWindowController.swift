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
    var onPauseFeatured: () -> Void = {}
    var onRevealFeatured: () -> Void = {}
    var onChooseFiles: () -> Void = {}
    var onConfirmSelection: (_ selectedBytes: Int64) -> Void = { _ in }
    var onCancelSelection: () -> Void = {}

    private var panel: NSPanel?
    private var hostingView: NotchContainerView?
    private var cancellables = Set<AnyCancellable>()

    private(set) var isAvailable = false
    private var geometry: NotchGeometry?
    private var currentFrame: CGRect = .zero

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

        if hasActivity {
            return center.isHovered ? .card : .pill
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
            frame = (notch.width, notch.height)
        case .pill:
            frame = (max(notch.width + 110, 250), notch.height + 34)
        case .card:
            frame = (340, notch.height + 150)
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
        center?.isHovered = hovering
        if !hovering {
            isDetailExpanded = false
        }
        refreshVisibility()
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

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

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
