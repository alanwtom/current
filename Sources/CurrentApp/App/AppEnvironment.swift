import Foundation
import Combine
import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import CurrentCore
import CurrentEngine
import CurrentSim

/// Composition root. Owns the engine and every store; routes engine events;
/// exposes the actions used by menus, commands, and views.
@MainActor
final class AppEnvironment: ObservableObject {

    let database: AppDatabase
    let settings: SettingsStore
    let library: LibraryStore
    let power: PowerMonitor
    let automation: AutomationCoordinator
    let cleanup: CleanupCenter
    let sidebarCounts: SidebarCounts
    /// Combined transfer rates for the chrome bar, coalesced to 1 Hz.
    let activity: ActivityModel
    let magnetFlow: MagnetFlowCenter
    let toasts: ToastCenter
    /// Menu bar item. Created after init because it needs `self` for actions.
    private(set) var statusItem: StatusItemController?

    private let engine: any TorrentEngine

    /// Failures reported by the engine between snapshot ticks.
    @Published var failures: [TorrentID: EngineFailure] = [:]
    @Published private(set) var recentCompletions: [String] = []
    /// Invoked by RootView to hand the environment the system "open settings" action.
    var requestOpenSettings: (() -> Void)?
    @Published var isCommandPaletteVisible = false
    @Published var pendingRemoval = Set<TorrentID>()
    @Published var isAddMagnetSheetVisible = false
    @Published var showMagnetFilePicker = false
    @Published var settingsTab: SettingsTab = .general
    @Published var isSettingsVisible = false
    /// Non-nil while the "close the window?" dialog is up. Holds the action
    /// that actually closes it, handed over by `WindowChrome`.
    @Published var pendingWindowClose: (() -> Void)?
    /// The launch intro plays once per run, not once per window — opening a
    /// second window shouldn't replay it. See `LaunchIntro`.
    @Published var isIntroPlaying = true

    private var eventTask: Task<Void, Never>?
    private var configCancellables = Set<AnyCancellable>()
    private var appliedConfiguration: EngineConfiguration?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Current", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let simulate = ProcessInfo.processInfo.arguments.contains("-simulate")

        let engine: any TorrentEngine = simulate
            ? SimulationEngine()
            : LibtorrentEngine()
        self.engine = engine

        let database = AppDatabase(url: appSupport.appendingPathComponent("library.sqlite"))
        self.database = database
        self.settings = SettingsStore(database: database)
        // Before any window exists, so the first frame is already the right
        // appearance. The property's own `didSet` handles later changes, but it
        // doesn't fire during `init`.
        AppearanceApplier.apply(settings.appearance)
        let library = LibraryStore(engine: engine, database: database, persistsRecords: !simulate)
        self.library = library
        self.power = PowerMonitor()

        let cleanup = CleanupCenter(library: library, database: database)
        self.cleanup = cleanup
        self.sidebarCounts = SidebarCounts(library: library, cleanup: cleanup)
        self.activity = ActivityModel(library: library)
        self.magnetFlow = MagnetFlowCenter()
        self.toasts = ToastCenter()

        self.automation = AutomationCoordinator(
            library: library,
            settings: settings,
            database: database,
            power: power
        )

        // Says so out loud when a magnet is abandoned. Two minutes after
        // clicking a link, a row vanishing without a word is the app looking
        // broken; this is the same rule the rest of the automation follows —
        // if it acts on its own, it explains itself.
        automation.onMagnetTimedOut = { [weak self] name in
            guard let self else { return }

            // Take the flow down with it. The coordinator removes the torrent,
            // but nothing told the flow — so the card sat there saying
            // "Resolving magnet…" indefinitely, about a torrent that no longer
            // existed, and the only way out was quitting the app.
            if case .resolving = self.magnetFlow.stage {
                self.magnetFlow.resolveFailed(message: name)
            }

            // Deliberately short. A toast truncates, and a warning that ends in
            // an ellipsis tells you less than a shorter one that finishes its
            // sentence — the first draft of this ran to two lines and was cut
            // off mid-word.
            self.toasts.show(
                .warning,
                title: "Couldn't get the file details",
                message: "No peers answered in two minutes. The link may be dead.",
                actionTitle: "Try Again",
                coalesceKey: "magnet.timeout",
                action: { [weak self] in self?.beginAddMagnet() }
            )
        }

        cleanup.onCleanupCompleted = { [weak self] summary in
            self?.toasts.show(
                .success,
                title: "\(ByteFormatting.bytes(summary.bytesReclaimed)) cleaned",
                message: "\(summary.torrentsCleaned) completed download\(summary.torrentsCleaned == 1 ? "" : "s") moved to Trash.",
                actionTitle: "View",
                coalesceKey: "cleanup",
                // "View" now goes somewhere: the section listing what cleanup
                // considered, so you can see what it took.
                action: { [weak self] in self?.library.activeSection = .readyToClean }
            )
        }

        if Bundle.main.bundleIdentifier != nil,
           ProcessInfo.processInfo.environment["CURRENT_NO_NOTIFICATIONS"] == nil {
            UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        }

        statusItem = StatusItemController(app: self, library: library)

        // Push session settings down whenever they change, and whenever the
        // power source does. This is what makes the settings real: before it
        // existed, "Keep downloading but slower when on battery" was a toggle
        // in Settings that no code anywhere read.
        //
        // Throttled and deduplicated — settings edits arrive per keystroke from
        // the steppers, and re-applying an identical configuration would put
        // avoidable work on the engine every time.
        for publisher in [settings.objectWillChange, power.objectWillChange] {
            publisher
                .throttle(for: .seconds(0.4), scheduler: RunLoop.main, latest: true)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.pushEngineConfiguration() }
                }
                .store(in: &configCancellables)
        }
        pushEngineConfiguration()

        eventTask = Task.detached(priority: .utility) { [engine] in
            let stream = await engine.events
            for await event in stream {
                await MainActor.run { self.route(event) }
            }
        }
    }

    /// Recomputes the session configuration and hands it to the engine if it
    /// actually changed.
    private func pushEngineConfiguration() {
        let onBattery = power.isOnBattery || power.isLowPowerMode
        let configuration = settings.engineConfiguration(onBattery: onBattery)
        guard configuration != appliedConfiguration else { return }
        appliedConfiguration = configuration
        Task { [engine] in await engine.apply(configuration) }
    }

    /// Plain-language reason the current speed limits are what they are, for
    /// Settings to show. Automatic behaviour has to explain itself.
    var bandwidthExplanation: String {
        settings.bandwidthPolicy.explanation(
            onBattery: power.isOnBattery || power.isLowPowerMode
        )
    }

    // MARK: - Event routing

    private func route(_ event: EngineEvent) {
        switch event {
        case .snapshots(let batch):
            library.applySnapshots(batch)

        case .metadataReceived(let id, let metadata):
            library.applyMetadata(metadata)
            library.updateNameIfNeeded(id, name: metadata.displayName)
            failures[id] = nil
            magnetFlow.metadataArrived(id: id)
            pauseForSelection(id)

        case .completed(let id):
            handleCompleted(id)

        case .failed(let id, let failure):
            failures[id] = failure
            if settings.notifyOnFailure {
                postNotification(
                    identifier: "failed-\(id.raw)",
                    title: failure.title,
                    body: library.snapshot(for: id)?.name ?? ""
                )
            }

        case .removed(let id):
            failures[id] = nil
            if case .selecting(let selectingID) = magnetFlow.stage, selectingID == id {
                magnetFlow.dismiss()
            }
        }
    }

    private func pauseForSelection(_ id: TorrentID) {
        guard case .selecting(id) = magnetFlow.stage else { return }
        // Freeze the torrent while the user picks files; resume applies choices.
        Task { await engine.pause(id) }
    }

    private func handleCompleted(_ id: TorrentID) {
        guard let snapshot = library.snapshot(for: id) else { return }
        let name = snapshot.name
        magnetFlow.downloadCompleted(name: name)
        recentCompletions.append(name)
        if recentCompletions.count > 5 {
            recentCompletions.removeFirst(recentCompletions.count - 5)
        }
        toasts.show(
            .success,
            title: "Download complete",
            message: name,
            actionTitle: "Reveal",
            coalesceKey: "complete-\(id.raw)",
            action: { [weak self] in self?.revealInFinder(id) }
        )
        if settings.notifyOnCompletion {
            postNotification(identifier: "done-\(id.raw)", title: "Download complete", body: name)
        }
    }

    // MARK: - Adding content

    func addMagnet(_ uri: String) async {
        let hint = DropParser.nameHint(fromMagnet: uri)
        magnetFlow.beginResolving(nameHint: hint)
        do {
            let id = try await engine.addMagnet(uri, saveDirectory: settings.downloadsFolder)
            library.registerAdded(id, name: hint, magnet: uri, saveDirectory: settings.downloadsFolder)
        } catch {
            magnetFlow.resolveFailed(message: error.localizedDescription)
            let failure = (error as? EngineFailure) ?? EngineFailure(kind: .unknown, technicalMessage: error.localizedDescription)
            toasts.show(.warning, title: failure.title, message: failure.explanation)
        }
    }

    func addTorrentFile(at url: URL) async {
        guard let data = try? Data(contentsOf: url) else {
            toasts.show(.warning, title: "Couldn't read torrent file", message: url.lastPathComponent)
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        // A .torrent file is a download like any other, so it gets the same
        // confirm card — which is what asks where it should go and which files
        // to take. It carries its metadata with it, so the resolving stage it
        // passes through is momentary.
        //
        // Only when nothing else is mid-flow, which is the guard that makes
        // opening a folder of ten .torrent files sane: the first one asks, the
        // rest go to the default folder rather than queueing ten questions.
        let claimsFlow = magnetFlow.stage == .idle
        if claimsFlow {
            magnetFlow.beginResolving(nameHint: name)
        }
        do {
            let id = try await engine.addTorrentFile(data, saveDirectory: settings.downloadsFolder)
            library.registerAdded(id, name: name, magnet: nil, saveDirectory: settings.downloadsFolder)
            if !claimsFlow {
                toasts.show(.info, title: "Added", message: name)
            }
        } catch let failure as EngineFailure where failure.kind == .duplicateTorrent {
            // Both failure paths have to take the flow down with them. It was
            // put into `.resolving` a moment ago for a torrent that now doesn't
            // exist, and a card left spinning about nothing is the exact bug the
            // magnet timeout already had to be fixed for.
            if claimsFlow { magnetFlow.dismiss() }
            toasts.show(.info, title: "Already in your library", message: "This torrent was added earlier.")
        } catch {
            if claimsFlow { magnetFlow.dismiss() }
            toasts.show(.warning, title: "Couldn't add torrent", message: error.localizedDescription)
        }
    }

    func handleDroppedItems(_ parsed: [DropParser.Parsed]) {
        for item in parsed {
            switch item {
            case .magnet(let uri):
                Task { await addMagnet(uri) }
            case .torrentFile(let url):
                Task { await addTorrentFile(at: url) }
            }
        }
    }

    // MARK: - Where a download goes

    /// The folder the download being confirmed will land in.
    ///
    /// The per-download choice wins; otherwise it's the settings default, which
    /// is also the folder the torrent was already added to.
    var downloadDestination: URL {
        magnetFlow.chosenDestination ?? settings.downloadsFolder
    }

    /// The folder chooser behind "Change…" on the confirm card.
    ///
    /// Deliberately the system's panel. This is the one interaction in the app
    /// where drawing our own would be strictly worse: people need their
    /// sidebar, their tags, their iCloud folders and the New Folder button, and
    /// none of that is ours to reinvent. Same reason the menus stay native.
    func chooseDownloadDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Choose where this download should go."
        panel.directoryURL = downloadDestination
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        magnetFlow.chosenDestination = url
    }

    // MARK: - Selection confirm / cancel from the flow surface

    /// Applies the user's file selection and starts the download.
    func applyMagnetSelection(_ priorities: [FilePriority]) async {
        guard case .selecting(let id) = magnetFlow.stage else { return }

        // Where it goes is settled here, not when it was added. At add time the
        // magnet was an unresolved hash — there was nothing to decide against,
        // so it went to the default folder. Now there's a name and a size on
        // screen, and this is the last moment before anything touches the disk.
        let destination = downloadDestination
        if library.records[id]?.saveDirectory != destination {
            await engine.setSaveDirectory(id, destination)
            library.updateSaveDirectory(id, destination)
        }
        if magnetFlow.remembersDestination {
            settings.downloadsFolder = destination
            settings.asksForDownloadLocation = false
        }

        library.setPriorities(priorities, for: id)
        magnetFlow.confirmSelection()
        await engine.resume(id)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            magnetFlow.handoffFinished()
        }
    }

    /// "Download everything" from the summary card.
    func applyAllFilesSelection(for id: TorrentID) async {
        guard let metadata = library.metadataCache[id] else { return }
        await applyMagnetSelection(
            Array(repeating: FilePriority.normal, count: metadata.files.count)
        )
    }

    func cancelMagnetSelection() async {
        if case .selecting(let id) = magnetFlow.stage {
            await engine.remove(id, deleteFiles: true)
            await library.remove([id], deleteFiles: false)
        }
        magnetFlow.dismiss()
    }

    // MARK: - Bulk actions

    func pauseAll() {
        for snapshot in library.snapshots.values where snapshot.state.isActive {
            Task { await library.engine.pause(snapshot.id) }
        }
    }

    func resumeAll() {
        for id in library.snapshots.keys {
            Task { await library.engine.resume(id) }
        }
    }

    func cleanEligibleNow() async {
        cleanup.refreshPlan()
        let plan = cleanup.plan.candidatesToReach(freeBytesTarget: overBudgetAmount())
        await cleanup.performCleanup(plan)
    }

    private func overBudgetAmount() -> Int64 {
        guard let limit = settings.storageLimitBytes else {
            return cleanup.plan.candidates.map(\.reclaimableBytes).reduce(0, +)
        }
        return max(0, library.usedStorageBytes - limit)
    }

    // MARK: - Small actions

    func revealInFinder(_ id: TorrentID) {
        guard let snapshot = library.snapshot(for: id) else { return }
        let folder = snapshot.saveDirectory.appendingPathComponent(snapshot.name)
        let target = FileManager.default.fileExists(atPath: folder.path)
            ? folder
            : snapshot.saveDirectory
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func togglePauseSelected() {
        library.togglePause(for: library.selection)
    }

    func confirmRemoval(of ids: Set<TorrentID>) {
        guard !ids.isEmpty else { return }
        pendingRemoval = ids
    }

    func removePending(deleteFiles: Bool) async {
        let ids = pendingRemoval
        pendingRemoval = []
        await library.remove(ids, deleteFiles: deleteFiles)
    }

    // MARK: - Window management

    /// Settings live inside the window now, not in a separate `Settings` scene.
    ///
    /// The scene version came with a system window: its own title bar, its own
    /// `TabView` of system tab icons, and its own set of stock form controls.
    /// Presenting settings as one of the app's own surfaces is both the Cursor
    /// model and the only way the pane can look like the rest of the app. ⌘,
    /// still opens it, because that is the shortcut people reach for.
    func openSettings(tab: SettingsTab) {
        settingsTab = tab
        isSettingsVisible = true
    }

    func beginAddMagnet() {
        isAddMagnetSheetVisible = true
    }

    /// A magnet link or a `.torrent` handed over by the system.
    ///
    /// The one entry point for both, called from `AppDelegate` — see there for
    /// why this doesn't live in `.onOpenURL`. Anything that isn't a magnet or a
    /// torrent is ignored rather than reported: the app is registered for those
    /// two things, so a third would mean the system got it wrong, and a dialog
    /// about it would be noise.
    func open(_ url: URL) {
        // Through `DropParser`, like drops and pastes, so all three routes into
        // the app agree about what counts as a magnet.
        switch DropParser.parse(url: url) {
        case .magnet(let uri):
            Task { await addMagnet(uri) }
        case .torrentFile(let file):
            Task { await addTorrentFile(at: file) }
        case nil:
            return
        }

        // Bring the app forward and make sure there's a window to watch it in.
        // Clicking a magnet in a browser is a request to see something happen,
        // and the flow is drawn *in* the window — which may well be closed,
        // since this app keeps running in the menu bar.
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Downloads that haven't finished yet.
    ///
    /// Seeding deliberately doesn't count. A torrent set to seed forever would
    /// otherwise make every single window close ask a question, which is exactly
    /// the kind of nagging this app is supposed to avoid.
    var unfinishedCount: Int {
        library.orderedIDs.reduce(into: 0) { total, id in
            switch library.snapshot(for: id)?.state {
            case .downloading, .checking, .resolving: total += 1
            default: break
            }
        }
    }

    /// Moved off the root view so the chrome bar, the command palette and the
    /// menu bar can all reach it without each keeping its own copy.
    func pickTorrentFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let type = UTType(filenameExtension: "torrent") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            Task { await addTorrentFile(at: url) }
        }
    }

    // MARK: - Notifications

    private func postNotification(identifier: String, title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: - Lifecycle

    private var isFinishedSetup = false

    /// Called once from the main window. Restores state and opens the door to
    /// magnet links the system delivered before there was an engine.
    func finishSetup() async {
        guard !isFinishedSetup else { return }
        isFinishedSetup = true

        AppDelegate.environment = self

        if ProcessInfo.processInfo.arguments.contains("-simulate") {
            await seedDemoLibraryIfRequested()
        } else {
            await library.restoreResumeData()
        }

        // Last, and only now: a magnet clicked in a browser launches the app,
        // so its URL was waiting here before there was an engine to hand it to.
        // Draining after the restore keeps the new magnet from racing the
        // torrents being resumed.
        AppDelegate.flushPendingURLs()
    }

    func prepareForTermination() async {
        // Drop the menu bar icon first so it doesn't sit there looking alive
        // while resume data is still being written.
        statusItem?.tearDown()
        statusItem = nil
        await library.saveAllResumeData()
        eventTask?.cancel()
    }

    func seedDemoLibraryIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-simulate") else { return }
        let samples: [(String, Double)] = [
            ("Ubuntu 26.04 LTS Desktop", 0.72),
            ("Big Buck Bunny (2008) 4K Remaster", 0.34),
            ("Blender Foundation Open Movies Collection", 0.91),
            ("Sintel (2010)", 1.0),
            ("Debian 13 netinst arm64", 0.12),
            ("Internet Archive Monthly Snapshot", 1.0),
        ]
        for (index, sample) in samples.enumerated() {
            let uri = "magnet:?xt=urn:btih:demo\(index)&dn=\(sample.0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sample.0)"
            _ = try? await engine.addMagnet(uri, saveDirectory: settings.downloadsFolder)
        }
    }
}

