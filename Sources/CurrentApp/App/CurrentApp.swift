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
                .frame(minWidth: 760, minHeight: 460)
                .onOpenURL { url in
                    handleIncoming(url)
                }
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(tab: Binding(
                get: { app.settingsTab },
                set: { app.settingsTab = $0 }
            ))
            .environmentObject(app.settings)
            .environmentObject(app)
            .environmentObject(app.library)
        }

        MenuBarExtra {
            StatusBarMenuContent()
                .environmentObject(app)
                .environmentObject(app.library)
        } label: {
            StatusBarLabel(store: app.library)
        }
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

/// Menu bar label that observes the library so speeds update live.
struct StatusBarLabel: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        let down = store.aggregateDownloadRate
        let up = store.aggregateUploadRate
        if down > 1 || up > 1 {
            Text("\(compact(down)) \(compact(up))")
                .tabularNumerics()
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }

    private func compact(_ rate: Double) -> String {
        guard rate > 1 else { return "—" }
        let text = ByteFormatting.rate(rate)
        return text.hasSuffix("/s") ? String(text.dropLast(2)) : text
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
