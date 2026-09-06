import Foundation
import Sparkle

/// Automatic updates, without a single Sparkle window.
///
/// The app exists because stock Mac chrome is what makes an app look like every
/// other Mac utility (see AGENTS.md). Sparkle's built-in controller draws
/// exactly that chrome, and it would be the *only* system UI Current ever
/// showed — and it would show up at the worst moment, unprompted, over the
/// user's library. So Sparkle's engine is used and its interface is not:
/// `QuietUpdateDriver` implements `SPUUserDriver` and routes the one moment
/// that genuinely needs the user through the app's own toast.
///
/// The shape of it:
///
/// - Nothing is checked until the user has answered the question in
///   `hasAnsweredUpdateQuestion`. Until then this class makes no network call
///   at all, which is what keeps the claim on the download page true.
/// - A background check that finds nothing, or fails, is **silent**. A user who
///   never asked to check should never learn that a check happened, least of
///   all through an error.
/// - Downloading happens quietly. The only interruption is one toast, once the
///   update is on disk and ready: *Version 1.1 is ready — Relaunch*.
/// - A check the user started from the menu is allowed to say "you're up to
///   date", because then they asked.
@MainActor
final class UpdateController {

    private let updater: SPUUpdater
    private let driver: QuietUpdateDriver
    private let settings: SettingsStore

    init(settings: SettingsStore, toasts: ToastCenter) {
        self.settings = settings
        self.driver = QuietUpdateDriver(toasts: toasts)

        let bundle = Bundle.main
        self.updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: driver,
            delegate: nil
        )

        // Sparkle's own scheduling is off in Info.plist; this class decides.
        updater.automaticallyChecksForUpdates = settings.checksForUpdatesAutomatically
        updater.automaticallyDownloadsUpdates = true

        do {
            try updater.start()

            // A test affordance, and the only way to check this path without
            // waiting on Sparkle's scheduler.
            //
            // `automaticallyChecksForUpdates` does not mean "check now" — Sparkle
            // spaces checks out on its own timer, which is right for a real
            // install and useless for proving the update path works. Setting
            // this variable asks for one check immediately, so
            // Scripts/test-update.sh can watch an install actually become the
            // next version. It does nothing unless the variable is set, and
            // nothing at all if the user hasn't agreed to checks.
            if ProcessInfo.processInfo.environment["CURRENT_UPDATE_CHECK_ON_LAUNCH"] != nil,
               settings.checksForUpdatesAutomatically {
                updater.checkForUpdatesInBackground()
            }
        } catch {
            // A broken updater must never stop the app launching. There is
            // nothing useful to tell the user here — they didn't ask for an
            // update, and a dialog about the updater failing to start is worse
            // than silently having no updater.
            NSLog("Current: updater did not start — \(error.localizedDescription)")
        }
    }

    /// Reflects a change made in Settings, or the answer to the first-launch
    /// question, into the running updater.
    func automaticChecksChanged(to enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }

    /// The menu item. A check the user asked for is allowed to talk back.
    func checkForUpdates() {
        driver.isUserInitiated = true
        updater.checkForUpdates()
    }

    /// Whether the menu item should be enabled.
    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
}

/// The `SPUUserDriver` that draws nothing.
///
/// Most of this protocol is progress reporting for Sparkle's window, and since
/// there is no window most of it is deliberately empty. The methods that do
/// something are marked; the rest are no-ops on purpose rather than by
/// omission, so a future reader can see the choice was made.
@MainActor
private final class QuietUpdateDriver: NSObject, SPUUserDriver {

    private let toasts: ToastCenter

    /// Set before a check the user started from the menu. Lets "no update
    /// found" be spoken aloud in that case and stay silent in every other.
    var isUserInitiated = false

    init(toasts: ToastCenter) {
        self.toasts = toasts
        super.init()
    }

    // MARK: - The permission question
    //
    // Never reached in practice: the app asks in its own card before ever
    // enabling checks, and `SUEnableAutomaticChecks` is false in Info.plist.
    // If Sparkle ever does ask, answer from what the user already told us and
    // decline the system profile — Current sends no profile, ever.

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    // MARK: - Checking

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        // No spinner. A check takes a moment and finishes into either a toast
        // or silence; a progress window for a network request that usually
        // takes under a second is the kind of thing this app doesn't do.
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // Found one: take it, quietly. The user is not asked here — they are
        // asked once it is downloaded and relaunching is all that's left, which
        // is the only moment their answer changes anything.
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        if isUserInitiated {
            toasts.show(
                .info,
                title: "Current is up to date",
                coalesceKey: "update.none"
            )
        }
        isUserInitiated = false
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // Only ever surfaced for a check the user started. A background check
        // that fails — no network, feed unreachable — is not news, and an app
        // that interrupts you to report a failed errand you never sent it on is
        // exactly the kind of thing this one is built not to be.
        if isUserInitiated {
            toasts.show(
                .warning,
                title: "Couldn't check for updates",
                message: error.localizedDescription
            )
        }
        isUserInitiated = false
        acknowledgement()
    }

    // MARK: - Downloading, silently

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}

    // MARK: - The one moment that interrupts

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // The whole visible surface of the updater: one toast with one button.
        // `coalesceKey` because a second check finding the same update must not
        // stack a second toast on the first.
        //
        // **Sparkle needs an answer, and exactly one.** This is the part that
        // caught me out and is worth stating plainly: replying only when the
        // button is pressed means an ignored toast never replies at all, and
        // Sparkle then waits forever — the update sits downloaded on disk and
        // is never installed, not on quit, not ever. It looks exactly like an
        // updater that silently doesn't work, which is what the end-to-end test
        // found.
        //
        // So there are two paths and both answer:
        //
        //   Relaunch  -> .install, restart now
        //   ignored   -> .dismiss, which is not "no". It tells Sparkle to stop
        //                waiting and install what it already downloaded the
        //                next time the app quits.
        //
        // Ignoring the toast is meant to be the ordinary case — you get the
        // update without ever being interrupted — so it has to be the case that
        // works.
        var hasReplied = false
        func answer(_ choice: SPUUserUpdateChoice) {
            guard !hasReplied else { return }
            hasReplied = true
            reply(choice)
        }

        toasts.show(
            .success,
            title: "An update is ready",
            message: "Relaunch Current to install it, or it will install when you quit.",
            actionTitle: "Relaunch",
            coalesceKey: "update.ready"
        ) {
            answer(.install)
        }

        // Comfortably longer than the toast's own life, so a press always wins
        // the race. If it has gone unanswered by then, it was ignored.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            answer(.dismiss)
        }

        isUserInitiated = false
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {}
}
