import XCTest
import Combine
import CurrentCore
@testable import CurrentApp

@MainActor
final class ShellPresentationTests: XCTestCase {
    private func makeStore() -> LibraryStore {
        LibraryStore(
            engine: RecordingEngine(),
            database: AppDatabase(url: URL(fileURLWithPath: "/unused"), inMemory: true),
            persistsRecords: false
        )
    }

    private func snapshot(_ id: String, state: TorrentState = .downloading) -> TorrentSnapshot {
        TorrentSnapshot(
            id: TorrentID(id), name: id, state: state, progress: 0.5,
            totalBytes: 1_000, downloadedBytes: 500,
            saveDirectory: URL(fileURLWithPath: "/tmp/shell-test")
        )
    }

    func testTransferProgressDoesNotPublishWindowLayoutChanges() async {
        let store = makeStore()
        var transfer = snapshot("active")
        store.applySnapshots([transfer])
        let model = ShellPresentation(library: store)
        let noLayoutChange = expectation(description: "Progress must stay in the live content")
        noLayoutChange.isInverted = true
        let subscription = model.$state.dropFirst().sink { _ in noLayoutChange.fulfill() }
        transfer.progress = 0.8
        transfer.downloadRate = 500
        store.applySnapshots([transfer])
        await fulfillment(of: [noLayoutChange], timeout: 0.1)
        withExtendedLifetime(subscription) {}
    }

    func testSectionAndSelectionReachTheLayoutAfterTheMutation() async {
        let store = makeStore()
        let transfer = snapshot("selected")
        store.applySnapshots([transfer])
        let model = ShellPresentation(library: store)
        let changed = expectation(description: "The latest section and selection reach the shell")
        let subscription = model.$state.dropFirst().sink { state in
            if state.section == .seeding && state.selectedID == transfer.id { changed.fulfill() }
        }
        store.selection = [transfer.id]
        store.activeSection = .seeding
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(model.state.selectedID, transfer.id)
        XCTAssertEqual(model.state.section, .seeding)
        withExtendedLifetime(subscription) {}
    }

    func testPausedStateRefreshesCommandTitleWithoutProgressInvalidation() async {
        let store = makeStore()
        var transfer = snapshot("selected")
        store.applySnapshots([transfer])
        store.selection = [transfer.id]
        let model = ShellPresentation(library: store)
        let paused = expectation(description: "Pause changes the command state")
        let subscription = model.$state.dropFirst().sink { state in
            if state.areSelectedPaused { paused.fulfill() }
        }
        transfer.state = .paused(.user)
        store.applySnapshots([transfer])
        await fulfillment(of: [paused], timeout: 1)
        XCTAssertTrue(model.state.areSelectedPaused)
        withExtendedLifetime(subscription) {}
    }
}
