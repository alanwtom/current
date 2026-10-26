import Combine
import CurrentCore
import Foundation

/// Only the library facts that can change the window's structure.
/// Transfer rates and progress belong to the live list and inspector instead.
@MainActor
final class ShellPresentation: ObservableObject {
    struct State: Equatable {
        var section: SidebarSection
        var selectedID: TorrentID?
        var areSelectedPaused: Bool
    }

    @Published private(set) var state: State
    private var subscription: AnyCancellable?

    init(library: LibraryStore) {
        state = Self.read(library)
        subscription = library.objectWillChange
            // Published properties notify before their values change. Read on
            // the next run-loop turn, after the complete batch has settled.
            .receive(on: RunLoop.main)
            .sink { [weak self, weak library] _ in
                MainActor.assumeIsolated {
                    guard let self, let library else { return }
                    let next = Self.read(library)
                    if next != self.state { self.state = next }
                }
            }
    }

    private static func read(_ library: LibraryStore) -> State {
        let selectedID: TorrentID? = library.selection.isEmpty ? nil : library.orderedIDs.first {
            library.selection.contains($0) && library.snapshot(for: $0) != nil
        }
        return State(
            section: library.activeSection,
            selectedID: selectedID,
            areSelectedPaused: !library.selection.isEmpty && library.selection.allSatisfy {
                library.snapshot(for: $0)?.state.isPaused ?? false
            }
        )
    }
}
