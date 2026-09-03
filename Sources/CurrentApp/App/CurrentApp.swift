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
                .onOpenURL { url in handleIncoming(url) }
        }
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

    private func handleIncoming(_ url: URL) {
        if url.isFileURL {
            if url.pathExtension.lowercased() == "torrent" {
                Task { await app.addTorrentFile(at: url) }
            }
        } else if url.scheme == "magnet" {
            Task { await app.addMagnet(url.absoluteString) }
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static weak var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Claim magnet links quietly; users can reassign later in System Settings.
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        LSSetDefaultHandlerForURLScheme("magnet" as CFString, bundleID as CFString)
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
