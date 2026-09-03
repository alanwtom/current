import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CurrentCore
import CurrentEngine
import CurrentSim

@main
struct CurrentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppEnvironment()

    var body: some Scene {
        WindowGroup("Current") {
            AppShell()
                .environmentObject(app)
                .environmentObject(app.library)
                .environmentObject(app.settings)
                .environmentObject(app.magnetFlow)
                .environmentObject(app.cleanup)
                .environmentObject(app.toasts)
                // Small enough for a Transmission-style strip. Below ~620pt
                // wide the app switches to its compact layout — see
                // WindowMetrics — and the modal surfaces shrink to fit rather
                // than hanging over the edges, which they used to. The number
                // is a token now because that's what the layout tests measure
                // against; this is the only place it takes effect, since
                // SwiftUI overwrites `NSWindow.contentMinSize`.
                .frame(
                    minWidth: Chrome.minimumWindowSize.width,
                    minHeight: Chrome.minimumWindowSize.height
                )
        }
        // Magnet links are handled by `AppDelegate.application(_:open:)`, not by
        // `.onOpenURL` here, and this is why: a `WindowGroup` treats an incoming
        // URL as a request for a *new* window, so clicking a magnet in a browser
        // opened a second, empty one every time — and on a cold launch the URL
        // was lost outright, because `.onOpenURL` only reaches views that
        // already exist and the URL arrives before the first one does.
        //
        // Implementing the delegate method takes the URL before any of that and
        // leaves the scene out of it. `.handlesExternalEvents(matching: [])`
        // looks like the tidier fix and is not: it also declines the *launch*
        // event, so an app opened by a magnet link came up with no window at
        // all.
        // The launch size is set from AppKit in `WindowChrome`, not with
        // `.defaultSize` — SwiftUI ignores that here and picks its own, because
        // this scene's content is fully flexible.
        // Every scrap of system window chrome is off. `WindowChrome` then takes
        // over from the AppKit side — hidden title, transparent title bar,
        // full-size content — and the app draws its own bar.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Commands live in the menu bar, not only on toolbar buttons: a
            // shortcut attached to a button dies whenever that button isn't on
            // screen, and several of ours drop out of the chrome bar in the
            // compact layout. AGENTS.md requires a keyboard path for every
            // mouse interaction, and the menu bar is the one place that exists
            // regardless of what the window is doing.
            CommandGroup(replacing: .newItem) {
                Button("Add Magnet Link…") { app.beginAddMagnet() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Torrent File…") { app.pickTorrentFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .pasteboard) {
                Button("Select All") {
                    NotificationCenter.default.post(name: .selectAllRequested, object: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.openSettings(tab: .general) }
                    .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Command Palette") {
                    app.isCommandPaletteVisible.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Toggle Sections") {
                    NotificationCenter.default.post(name: .toggleSidebarRequested, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Find") {
                    NotificationCenter.default.post(name: .focusSearchRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button("Pause All") { app.pauseAll() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Resume All") { app.resumeAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Clean Eligible Downloads…") {
                    Task { await app.cleanEligibleNow() }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }

        // There is no `Settings` scene any more: settings are one of the app's
        // own surfaces, presented in-window. See `SettingsSurface` for why.
        //
        // The menu bar item is owned by AppEnvironment's StatusItemController
        // rather than declared here — see `StatusItem.swift` for why
        // `MenuBarExtra` could not be used.
    }

}

// MARK: - App delegate

/// Also the app's URL handler, which is the whole reason it takes magnet links
/// at all.
///
/// Clicking a magnet link in a browser is the main way anyone adds a torrent,
/// and it was broken in two directions at once:
///
/// - **With the app closed, the link was lost.** LaunchServices launched the
///   app and delivered the URL immediately; `.onOpenURL` on the window group
///   only reaches views that already exist, and at that moment none did. The
///   app opened to an empty library as though nothing had been clicked.
/// - **With the app open, a second empty window appeared.** A `WindowGroup`
///   reads an incoming URL as a request for a new window.
///
/// An `NSApplicationDelegate` gets the URL before any of that, so this is where
/// it belongs. URLs that arrive before the engine exists wait in `pending`
/// rather than being dropped — on a cold launch that is *every* URL.
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static weak var environment: AppEnvironment?

    /// Main-thread only: AppKit delivers URLs there, and the environment
    /// registers itself from there.
    nonisolated(unsafe) private static var pending: [URL] = []

    /// `'GURL'` — the Apple Event a browser sends when you click a link the app
    /// is registered for. Written as raw four-character codes to avoid dragging
    /// Carbon in for three constants.
    private static let getURLEventClass = AEEventClass(0x4755_524C)  // 'GURL'
    private static let getURLEventID = AEEventID(0x4755_524C)        // 'GURL'
    private static let directObjectKeyword = AEKeyword(0x2D2D_2D2D)  // '----'

    /// Takes the URL event over from SwiftUI, and that is the point.
    ///
    /// Handling `application(_:open:)` is enough to *receive* magnet links but
    /// not enough to stop SwiftUI acting on them too: the adaptor wraps this
    /// delegate rather than replacing it, so the window group still read every
    /// URL as a request for a new window and opened an empty one beside the
    /// real one — once per link clicked. Our own handler for the event replaces
    /// the one underneath, so the scene never hears about it.
    ///
    /// **`willFinishLaunching`, not `didFinishLaunching`.** The URL that
    /// *launches* the app is delivered as soon as launching finishes, so a
    /// handler installed at the later hook arrives after AppKit has already
    /// dispatched it — which is exactly the case that matters, because clicking
    /// a magnet link with the app closed is the common one. Installed at the
    /// earlier hook it catches both.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReply:)),
            forEventClass: Self.getURLEventClass,
            andEventID: Self.getURLEventID
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Claim magnet links quietly; users can reassign later in System Settings.
        if let bundleID = Bundle.main.bundleIdentifier {
            LSSetDefaultHandlerForURLScheme("magnet" as CFString, bundleID as CFString)
        }
    }

    @objc
    private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: Self.directObjectKeyword)?.stringValue,
              let url = URL(string: string)
        else { return }
        MainActor.assumeIsolated { Self.deliver(url) }
    }

    /// Still implemented, because this is the path a `.torrent` dropped on the
    /// app icon takes — that arrives as an open-files event, not as `'GURL'`.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { Self.deliver(url) }
        }
    }

    @MainActor
    private static func deliver(_ url: URL) {
        guard let environment else {
            pending.append(url)
            return
        }
        environment.open(url)
    }

    /// Called by `AppEnvironment` once it can actually act on a URL.
    @MainActor
    static func flushPendingURLs() {
        guard let environment, !pending.isEmpty else { return }
        let urls = pending
        pending.removeAll()
        for url in urls { environment.open(url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Persist engine resume data so relaunch restores everything exactly.
        // The save itself is MainActor-isolated, so the main thread must stay
        // free to run it — blocking here (semaphore, sleep) would deadlock.
        guard let environment = Self.environment else { return .terminateNow }
        Task { @MainActor in
            await environment.prepareForTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
