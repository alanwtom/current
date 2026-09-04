import AppKit
import Combine
import SwiftUI
import CurrentCore

/// Owns the menu bar item.
///
/// This is deliberately AppKit rather than SwiftUI's `MenuBarExtra`, and that
/// is not a style preference — `MenuBarExtra` crashed the app about ten seconds
/// after launch, every launch, as soon as a transfer got moving.
///
/// The mechanism: SwiftUI flushes its pending menu bar updates from *inside*
/// the main window's layout pass, and each flush replaces the status item's
/// image. Replacing that image invalidates the status bar window's constraints,
/// so AppKit counts another constraint pass on a window that is already
/// mid-layout. The torrent list redraws about once a second, so this repeated
/// until AppKit gave up with "the window has been marked as needing another
/// Update Constraints in Window pass, but it has already had more … than there
/// are views in the window" and trapped. Nothing in our own view code could
/// avoid it: a completely static label with no observed state still crashed,
/// because the flush is driven by the window's redraw, not by our data.
///
/// Owning the status item ourselves means updates happen on our own throttled
/// tick, never inside somebody else's layout pass, and we set the button's
/// title instead of swapping its image.
@MainActor
final class StatusItemController {

    /// Twice a second is as often as a glanceable readout is worth redrawing.
    private static let tick: TimeInterval = 0.5

    /// How long rates must stay quiet before the readout drops back to the bare
    /// icon. Without this, a torrent hovering around zero flaps the menu bar
    /// item between two widths every tick.
    private static let idleGrace: TimeInterval = 5

    private let item: NSStatusItem
    private weak var app: AppEnvironment?
    private weak var library: LibraryStore?

    private var lastActivity: Date?
    private var shownTitle: String = ""
    private var shownTint: NSColor?
    private var cancellable: AnyCancellable?

    /// The panel behind the icon, and everything that keeps it honest.
    private let panelModel: StatusPanelModel
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var panelObserver: NSObjectProtocol?

    init(app: AppEnvironment, library: LibraryStore) {
        self.app = app
        self.library = library
        self.panelModel = StatusPanelModel(library: library)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            button.imagePosition = .imageLeading
            // Tabular figures so the width doesn't jitter as speeds change.
            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .regular
            )
            // No `item.menu`. Setting that hands the click to AppKit, which
            // opens a menu hanging from the item's left edge — the "uncentered
            // and boring" thing this replaced. Taking the action ourselves is
            // what lets a real panel open, centred under the icon.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        cancellable = library.objectWillChange
            .throttle(for: .seconds(Self.tick), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshTitle()
                    // Only while the panel is on screen. Closed, it costs
                    // nothing and observes nothing.
                    if self?.panel != nil { self?.panelModel.refresh() }
                }
            }
        refreshTitle()
    }

    deinit {
        // `item` is MainActor-isolated state; the status bar keeps its own
        // reference, so removal happens in `tearDown`.
    }

    /// Called before the app quits so the icon doesn't linger in the menu bar.
    func tearDown() {
        cancellable = nil
        closePanel()
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: - Readout

    /// This is the app's ambient presence with the window closed — the one
    /// place "something is happening" has to be legible without opening
    /// anything, on every Mac.
    private func refreshTitle() {
        guard let library, let button = item.button else { return }
        let snapshots = library.orderedIDs.compactMap { library.snapshot(for: $0) }
        let activity = LibraryActivity.summarize(snapshots)

        let rate = activity?.headlineRate ?? 0
        if rate > 1 { lastActivity = Date() }
        let withinGrace = lastActivity.map {
            -$0.timeIntervalSinceNow < Self.idleGrace
        } ?? false

        // Progress through the queue, then the rate that matters for whatever
        // state we're in. The count alone is the useful part at a glance; the
        // rate drops away once things settle so the menu bar goes quiet.
        var title = ""
        if let activity {
            title = " \(activity.done)/\(activity.total)"
            if rate > 1 || withinGrace {
                title += "  \(ByteFormatting.rate(rate))"
            }
        }

        let tint = Self.tint(for: activity)

        // Assigning the same values still dirties layout, so only write on a
        // real change. Most ticks are no-ops.
        if title != shownTitle {
            shownTitle = title
            button.title = title
        }
        if tint != shownTint {
            shownTint = tint
            button.image = Self.markImage(tint: tint)
        }
    }

    /// State colours come from the app's own palette so a torrent is the same
    /// colour here as it is in the list. Red is reserved for failure — a
    /// healthy seeding torrent glowing red would read as a problem.
    private static func tint(for activity: LibraryActivity?) -> NSColor {
        guard let activity else { return NSColor(Theme.textTertiary) }
        // The app's own tokens, not `controlAccentColor` / `systemTeal`, so a
        // torrent is the same colour here as it is in the list. At 15pt the
        // colour is most of what this icon can say.
        switch activity.dominant {
        case .downloading: return NSColor(Theme.downloading)
        case .seeding: return NSColor(Theme.seeding)
        case .complete: return NSColor(Theme.complete)
        case .failed: return NSColor(Theme.failure)
        }
    }

    /// The app mark, drawn to match the app icon so the menu bar is
    /// recognisably this app. Bars rather than the icon's waves: at 14pt the
    /// wave crests are under a pixel and only make the shape look furry, which
    /// is why the icon's own 16pt artwork flattens too.
    ///
    /// Not a template image — the whole point is the state colour.
    private static func markImage(tint: NSColor) -> NSImage {
        let size = NSSize(width: 15, height: 14)
        let image = NSImage(size: size, flipped: false) { _ in
            tint.setFill()
            // Narrowing bars, then the drop they arrive at.
            let bars: [(width: CGFloat, y: CGFloat)] = [
                (15, 11), (10, 7.5), (5.5, 4),
            ]
            for bar in bars {
                NSBezierPath(
                    roundedRect: NSRect(
                        x: (size.width - bar.width) / 2, y: bar.y,
                        width: bar.width, height: 2.2
                    ),
                    xRadius: 1.1, yRadius: 1.1
                ).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: size.width / 2 - 1.3, y: 0.4, width: 2.6, height: 2.6)).fill()
            return true
        }
        image.accessibilityDescription = "Current"
        return image
    }

    // MARK: - Panel

    @objc private func statusItemClicked() {
        panel == nil ? openPanel() : closePanel()
    }

    private func openPanel() {
        guard let button = item.button, let buttonWindow = button.window else { return }

        // Decide the rows before measuring, because the panel's height is
        // measured from them and then never changes while it's open.
        panelModel.freeze()

        let hosting = NSHostingView(rootView: makePanelView())
        // Measured once, here. Letting the window track its content instead
        // would mean re-measuring on every engine tick, which is the exact
        // shape of the bug that has taken this app down twice.
        let windowWidth = StatusPanelMetrics.width + StatusPanelMetrics.shadowMargin * 2
        hosting.setFrameSize(
            NSSize(width: windowWidth, height: hosting.fittingSize.height)
        )
        let size = hosting.frame.size

        let panel = StatusBarPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws its own shadow into the window's transparent margin.
        // AppKit's would sit on the window's square edge, so the two together
        // gave a soft glow with a hard rectangle inside it.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.setFrameOrigin(origin(for: size, under: button, in: buttonWindow))

        // Key, but non-activating. The panel has real buttons in it, and a
        // panel that can't become key gets no keyboard and no reliable clicks —
        // that failure is on the record here, it's half of why the notch panel
        // was removed. `canBecomeKey` is overridden below; `.nonactivatingPanel`
        // keeps the app from stealing focus from whatever you were using.
        panel.makeKeyAndOrderFront(nil)
        button.isHighlighted = true
        self.panel = panel

        // Two ways out, because neither covers the other: the monitor catches
        // a click in another app, and `didResignKey` catches ⌘-tab, Mission
        // Control, and anything else that takes focus without a click.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
        panelObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func closePanel() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let panelObserver {
            NotificationCenter.default.removeObserver(panelObserver)
            self.panelObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        item.button?.isHighlighted = false
        panelModel.thaw()
    }

    /// Centred under the icon, and kept on screen.
    ///
    /// A status item near the right edge would otherwise hang a 324pt panel
    /// off the side of the display — which is what "uncentered" looked like
    /// from the other direction. The clamp is why centring is safe to ask for.
    private func origin(for size: NSSize, under button: NSStatusBarButton, in window: NSWindow) -> NSPoint {
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        // The window is bigger than the card by the shadow margin on every
        // side, so both axes cancel it out — otherwise the card would sit
        // 22pt low and 22pt to the left of where the icon is.
        let inset = StatusPanelMetrics.shadowMargin
        var x = buttonRect.midX - size.width / 2
        let y = buttonRect.minY - size.height - StatusPanelMetrics.menuBarGap + inset

        if let screen = window.screen ?? NSScreen.main {
            // The card, not the window, is what has to stay on screen; the
            // margin around it is empty and may hang off the edge.
            let edge: CGFloat = 8
            let minX = screen.visibleFrame.minX + edge - inset
            let maxX = screen.visibleFrame.maxX - size.width - edge + inset
            x = min(max(x, minX), max(minX, maxX))
        }
        return NSPoint(x: x, y: y)
    }

    private func makePanelView() -> some View {
        StatusPanelView(
            model: panelModel,
            onTogglePause: { [weak self] id in
                self?.library?.togglePause(for: [id])
                self?.panelModel.refresh()
            },
            onReveal: { [weak self] id in
                self?.app?.revealInFinder(id)
                self?.closePanel()
            },
            onOpenTorrent: { [weak self] id in
                self?.library?.selection = [id]
                self?.activateWindow()
                self?.closePanel()
            },
            onPauseAll: { [weak self] in
                self?.app?.pauseAll()
                self?.panelModel.refresh()
            },
            onResumeAll: { [weak self] in
                self?.app?.resumeAll()
                self?.panelModel.refresh()
            },
            onAdd: { [weak self] in
                self?.closePanel()
                self?.activateWindow()
                self?.app?.beginAddMagnet()
            },
            onOpenApp: { [weak self] in
                self?.closePanel()
                self?.activateWindow()
            },
            onSettings: { [weak self] in
                self?.closePanel()
                self?.activateWindow()
                self?.app?.openSettings(tab: .general)
            },
            onQuit: { NSApp.terminate(nil) },
            onDismiss: { [weak self] in self?.closePanel() }
        )
    }

    private func activateWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}

/// A borderless panel that can still take the keyboard.
///
/// `.nonactivatingPanel` on its own gives you a surface that draws but never
/// becomes key, so its buttons need two clicks and its fields never focus.
/// Overriding `canBecomeKey` is the whole difference between a panel you can
/// use and one you can only look at.
private final class StatusBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Escape closes it, like every other summoned surface in the app.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
