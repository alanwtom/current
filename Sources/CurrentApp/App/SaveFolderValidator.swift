import AppKit
import CurrentCore

/// Refuses unsafe download folders inside the open panel itself.
///
/// The panel shows the reason and stays open, so the choice can be corrected
/// where it was made — by keyboard as much as by mouse — rather than being
/// accepted and then rejected somewhere else.
final class SaveFolderValidator: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let reason = SaveLocation.refusal(for: url, home: home) {
            throw NSError(domain: "dev.alantom.current", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    /// Runs `panel` with this validator attached for as long as it's open.
    @MainActor
    static func run(_ panel: NSOpenPanel) -> URL? {
        let validator = SaveFolderValidator()
        panel.delegate = validator
        defer { panel.delegate = nil }
        return withExtendedLifetime(validator) {
            panel.runModal() == .OK ? panel.url : nil
        }
    }
}
