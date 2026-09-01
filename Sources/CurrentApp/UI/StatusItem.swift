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

    /// Matches the notch's throttle. Twice a second is as often as a
    /// glanceable readout is worth redrawing.
    private static let tick: TimeInterval = 0.5

    /// How long rates must stay quiet before the readout drops back to the bare
    /// icon. Without this, a torrent hovering around zero flaps the menu bar
    /// item between two widths every tick.
    private static let idleGrace: TimeInterval = 5

    private let item: NSStatusItem
    private let menu = NSMenu()
    private weak var app: AppEnvironment?
    private weak var library: LibraryStore?

    private var lastActivity: Date?
    private var shownTitle: String = ""
    private var cancellable: AnyCancellable?
    private let menuDelegate = MenuDelegate()

    init(app: AppEnvironment, library: LibraryStore) {
        self.app = app
        self.library = library

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            // Set once and never replaced — see the note above about images.
            button.image = NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: "Current"
            )
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            // Tabular figures so the width doesn't jitter as speeds change.
            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.smallSystemFontSize,
                weight: .regular
            )
        }

        menuDelegate.onOpen = { [weak self] in self?.rebuildMenu() }
        menu.delegate = menuDelegate
        item.menu = menu
        rebuildMenu()

        cancellable = library.objectWillChange
            .throttle(for: .seconds(Self.tick), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTitle() }
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
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: - Readout

    private func refreshTitle() {
        guard let library, let button = item.button else { return }
        let down = library.aggregateDownloadRate
        let up = library.aggregateUploadRate
        let moving = down > 1 || up > 1
        if moving { lastActivity = Date() }

        let withinGrace = lastActivity.map {
            -$0.timeIntervalSinceNow < Self.idleGrace
        } ?? false

        let title = (moving || withinGrace)
            ? " \(Self.compact(down)) \(Self.compact(up))"
            : ""

        // Assigning the same title still dirties layout, so only write on a
        // real change. Most ticks are no-ops.
        guard title != shownTitle else { return }
        shownTitle = title
        button.title = title
    }

    private static func compact(_ rate: Double) -> String {
        guard rate > 1 else { return "—" }
        let text = ByteFormatting.rate(rate)
        return text.hasSuffix("/s") ? String(text.dropLast(2)) : text
    }

    // MARK: - Menu

    /// Rebuilt each time the menu opens, so the numbers are current without
    /// anything having to observe the library while the menu is closed.
    private func rebuildMenu() {
        menu.removeAllItems()
        guard let app, let library else { return }

        menu.addItem(disabled(summary(for: library)))
        menu.addItem(disabled("\(library.activeDownloadCount) active"))
        menu.addItem(.separator())

        menu.addItem(action("Pause All") { [weak app] in app?.pauseAll() })
        menu.addItem(action("Resume All") { [weak app] in app?.resumeAll() })

        let completions = Array(app.recentCompletions.suffix(3))
        if !completions.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabled("Recently finished"))
            for name in completions {
                let entry = disabled(name)
                entry.image = NSImage(
                    systemSymbolName: "checkmark.circle",
                    accessibilityDescription: nil
                )
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let open = action("Open Current") {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        open.keyEquivalent = "0"
        open.keyEquivalentModifierMask = .command
        menu.addItem(open)

        menu.addItem(.separator())
        let quit = action("Quit Current") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
    }

    private func summary(for library: LibraryStore) -> String {
        let down = library.aggregateDownloadRate
        let up = library.aggregateUploadRate
        let downText = down > 1 ? Self.compact(down) : "0"
        let upText = up > 1 ? Self.compact(up) : "0"
        return "\u{2193} \(downText)/s  \u{2191} \(upText)/s"
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func action(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: #selector(ActionTarget.fire), keyEquivalent: "")
        let target = ActionTarget(handler: handler)
        entry.target = target
        entry.representedObject = target   // menu items don't retain their target
        return entry
    }

    /// NSMenuItem holds its target weakly, so the closure needs an owner that
    /// lives as long as the item does.
    private final class ActionTarget: NSObject {
        private let handler: () -> Void
        init(handler: @escaping () -> Void) { self.handler = handler }
        @objc func fire() { handler() }
    }

    private final class MenuDelegate: NSObject, NSMenuDelegate {
        var onOpen: (() -> Void)?
        func menuNeedsUpdate(_ menu: NSMenu) { onOpen?() }
    }
}
