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
            RootView()
                .environmentObject(app)
                .environmentObject(app.library)
                .environmentObject(app.settings)
                .environmentObject(app.magnetFlow)
                .environmentObject(app.cleanup)
                .environmentObject(app.toasts)
                // Small enough for a Transmission-style strip. Below ~620pt wide the
                // app switches to its compact layout — see WindowMetrics.
                .frame(minWidth: 380, minHeight: 260)
                .onOpenURL { url in
                    handleIncoming(url)
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            // ⌘K used to live only on the toolbar button, which meant the
            // shortcut died whenever that button wasn't on screen — it now
            // drops out of the toolbar in the compact layout. AGENTS.md
            // requires a keyboard path for every mouse interaction, so the
            // command belongs in the menu bar where it exists regardless of
            // what the toolbar is doing. It is also simply easier to find.
            CommandGroup(after: .toolbar) {
                Button("Command Palette") {
                    app.isCommandPaletteVisible.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView(tab: Binding(
                get: { app.settingsTab },
                set: { app.settingsTab = $0 }
            ))
            .environmentObject(app.settings)
            .environmentObject(app)
            .environmentObject(app.library)
        }

        // The menu bar item is owned by AppEnvironment's StatusItemController,
        // not declared here — see the note in StatusBarExtra.swift for why
        // MenuBarExtra could not be used.
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
