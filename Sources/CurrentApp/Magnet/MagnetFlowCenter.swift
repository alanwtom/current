import Foundation
import CurrentCore

/// State machine for the signature interaction:
/// magnet → resolving → file selection → downloading → completion.
///
/// It presents in one place: `MagnetFlowOverlayView`, above the library. There
/// used to be a second presentation pinned to the camera housing, and this
/// machine existed partly so the two could never disagree about which stage
/// the flow was in. The notch panel is gone — everything that asks the user a
/// question now asks it in the window, where the answer is next to the library
/// it changes.
@MainActor
final class MagnetFlowCenter: ObservableObject {

    enum Stage: Equatable {
        case idle
        case resolving(nameHint: String?, startedAt: Date)
        case selecting(TorrentID)
        case starting(TorrentID)
        case completed(name: String)

        var isActive: Bool { self != .idle }
    }

    @Published var stage: Stage = .idle

    /// The folder the user picked for *this* download, if they picked one.
    ///
    /// Nil means "wherever the settings say", which is also where the torrent
    /// was added, so nil is the case that needs no work at all. It has to be
    /// per-flow rather than a setting, because choosing a folder once for one
    /// film is not the same as changing where everything goes — that second
    /// thing is what the Remember tick is for.
    @Published var chosenDestination: URL?

    /// Whether this download's folder should become the default and end the
    /// question. Reset with every new magnet: a decision to stop being asked is
    /// deliberate, and shouldn't carry over from the last thing you added.
    @Published var remembersDestination = false

    private var selectingID: TorrentID?

    // MARK: - Transitions

    func beginResolving(nameHint: String?) {
        chosenDestination = nil
        remembersDestination = false
        stage = .resolving(nameHint: nameHint, startedAt: Date())
    }

    func metadataArrived(id: TorrentID) {
        guard case .resolving = stage else { return }
        selectingID = id
        stage = .selecting(id)
    }

    func confirmSelection() {
        guard let id = selectingID else { return }
        stage = .starting(id)
    }

    func handoffFinished() {
        guard case .starting = stage else { return }
        stage = .idle
    }

    func downloadCompleted(name: String) {
        stage = .completed(name: name)
        // One short celebration, then back to quiet. Never lingers.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await MainActor.run { [weak self] in
                guard let self, case .completed = self.stage else { return }
                self.dismiss()
            }
        }
    }

    func dismiss() {
        stage = .idle
        selectingID = nil
        chosenDestination = nil
        remembersDestination = false
    }

    func resolveFailed(message: String) {
        dismiss()
    }
}
