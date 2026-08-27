import SwiftUI
import CurrentCore

/// Quick-control surface in the menu bar. Deliberately small: speeds,
/// pause/resume everything, and the latest completions.
struct StatusBarMenuContent: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        Section {
            Text(menuSummary)
                .font(.body.monospacedDigit())
            Text("\(store.activeDownloadCount) active")
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Pause All") { app.pauseAll() }
        Button("Resume All") { app.resumeAll() }

        if !recentlyCompleted.isEmpty {
            Divider()
            Section("Recently finished") {
                ForEach(recentlyCompleted, id: \.self) { name in
                    Label(name, systemImage: "checkmark.circle")
                        .lineLimit(1)
                }
            }
        }

        Divider()

        Button("Open Current") {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        .keyboardShortcut("0", modifiers: .command)

        Divider()
        Button("Quit Current") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var menuSummary: String {
        let down = store.aggregateDownloadRate
        let up = store.aggregateUploadRate
        let downText = down > 1 ? ByteFormatting.rate(down).replacingOccurrences(of: "/s", with: "") : "0"
        let upText = up > 1 ? ByteFormatting.rate(up).replacingOccurrences(of: "/s", with: "") : "0"
        return "\u{2193} \(downText)/s  \u{2191} \(upText)/s"
    }

    private var recentlyCompleted: [String] {
        Array(app.recentCompletions.suffix(3))
    }
}
