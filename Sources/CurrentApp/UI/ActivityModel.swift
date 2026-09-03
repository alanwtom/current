import SwiftUI
import Combine
import CurrentCore

/// The library's combined transfer rates, for the chrome bar.
///
/// A coalesced model rather than reading `LibraryStore` from the bar directly,
/// and that is not optional politeness — AGENTS.md makes it a rule. The chrome
/// bar sits at the very top of the window, so a view up there that re-renders on
/// every engine tick is renegotiating the window's layout once a second, which
/// is the failure that has killed this app twice.
///
/// So: throttled to one second, published only when the numbers actually change,
/// and displayed at a fixed width so even a real change can't resize anything.
@MainActor
final class ActivityModel: ObservableObject {

    private static let tick: TimeInterval = 1

    @Published private(set) var activity: LibraryActivity?
    /// True when anything at all is moving. Drives the bar's live dot.
    var isActive: Bool { (activity?.headlineRate ?? 0) > 0 }

    private var cancellables = Set<AnyCancellable>()

    init(library: LibraryStore) {
        recompute(library: library)

        library.objectWillChange
            .throttle(for: .seconds(Self.tick), scheduler: RunLoop.main, latest: true)
            .sink { [weak self, weak library] _ in
                MainActor.assumeIsolated {
                    guard let self, let library else { return }
                    self.recompute(library: library)
                }
            }
            .store(in: &cancellables)
    }

    private func recompute(library: LibraryStore) {
        let next = LibraryActivity.summarize(library.orderedIDs.compactMap { library.snapshot(for: $0) })
        guard next != activity else { return }
        activity = next
    }
}

/// The two combined rates, drawn as one quiet readout.
///
/// Only the rates that are non-zero appear, so an idle app shows nothing at all
/// here — the window's top edge stays completely still until something is
/// actually happening. That is the whole premise of the app: quiet when idle,
/// informative when active.
struct ActivityReadout: View {
    @EnvironmentObject private var activity: ActivityModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.l) {
            if let summary = activity.activity, summary.downloadRate > 1 {
                rate(summary.downloadRate, symbol: "arrow.down", tint: Theme.downloading)
            }
            if let summary = activity.activity, summary.uploadRate > 1 {
                rate(summary.uploadRate, symbol: "arrow.up", tint: Theme.seeding)
            }
        }
        .animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: activity.isActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func rate(_ value: Double, symbol: String, tint: Color) -> some View {
        HStack(spacing: Space.xs) {
            // The arrow is tinted; the number beside it is not. Same rule the
            // library rows follow — colour identifies, data stays grey.
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(tint)
            Text(ByteFormatting.rate(value))
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .numericTransition()
                .foregroundStyle(Theme.textSecondary)
        }
        // Fixed, so a rate crossing from 9.9 to 10.1 MB/s can't widen the bar
        // and set the window re-measuring.
        .frame(width: 74, alignment: .leading)
        .transition(.opacity)
    }

    private var accessibilityText: String {
        guard let summary = activity.activity else { return "Idle" }
        var parts: [String] = []
        if summary.downloadRate > 1 { parts.append("downloading at \(ByteFormatting.rate(summary.downloadRate))") }
        if summary.uploadRate > 1 { parts.append("uploading at \(ByteFormatting.rate(summary.uploadRate))") }
        return parts.isEmpty ? "Idle" : parts.joined(separator: ", ")
    }
}
