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

    /// The one torrent this flow is about, once the engine has said which it is.
    ///
    /// **The card belongs to one torrent, and only that torrent's metadata may
    /// move it on.** `metadataArrived` used to accept any id at all while
    /// resolving, so whichever torrent happened to resolve first took the card:
    /// a second magnet, or on a cold launch a torrent being restored from disk.
    /// The one the user actually clicked then never got asked about.
    private(set) var awaitedID: TorrentID?

    // MARK: - Transitions

    /// Starts the flow for a new download, if nothing else is using it.
    ///
    /// Returns false when a flow is already running. It used to overwrite
    /// whatever was on screen, which silently abandoned the first download
    /// mid-question — and that download, never paused, went ahead with every
    /// file. The caller adds the newcomer held instead, so it waits in the
    /// library rather than either starting unasked or queueing a question.
    @discardableResult
    func beginResolving(nameHint: String?) -> Bool {
        guard stage == .idle else { return false }
        chosenDestination = nil
        remembersDestination = false
        awaitedID = nil
        stage = .resolving(nameHint: nameHint, startedAt: Date())
        return true
    }

    /// Names the torrent the resolving card is waiting for. The engine only
    /// knows the id once the add returns, which is after the card is up.
    func awaiting(_ id: TorrentID) {
        guard case .resolving = stage else { return }
        awaitedID = id
    }

    /// Moves to the selection card if this is the torrent the flow is for.
    /// Returns whether it was.
    @discardableResult
    func metadataArrived(id: TorrentID) -> Bool {
        guard case .resolving = stage, awaitedID == id else { return false }
        selectingID = id
        stage = .selecting(id)
        return true
    }

    /// The engine dropped a torrent. If it was this flow's, the card goes too —
    /// a card about a torrent that no longer exists can't be answered.
    func torrentRemoved(_ id: TorrentID) {
        if awaitedID == id || selectingID == id {
            dismiss()
        }
    }

    func confirmSelection() {
        guard let id = selectingID else { return }
        stage = .starting(id)
    }

    func handoffFinished() {
        guard case .starting = stage else { return }
        stage = .idle
        awaitedID = nil
        selectingID = nil
    }

    func downloadCompleted(name: String) {
        // Only over an idle or finishing flow. Any torrent can complete at any
        // moment, and this used to replace whatever was showing — including a
        // "which files?" card for a different torrent, which then vanished and
        // left that torrent held with nothing left to release it.
        switch stage {
        case .idle, .starting, .completed: break
        case .resolving, .selecting: return
        }
        awaitedID = nil
        selectingID = nil
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
        awaitedID = nil
        selectingID = nil
        chosenDestination = nil
        remembersDestination = false
    }
}
