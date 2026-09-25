import Foundation

/// Which folders may receive downloads.
///
/// A torrent decides its own file names, and libtorrent writes into files that
/// already exist at those names. With the home folder as the save folder, a
/// single-file torrent called `.zshrc` replaces the user's shell startup file;
/// one called `Library` with `LaunchAgents/x.plist` inside it installs
/// something that runs at every login. The confirm card shows the paths, but
/// nobody reads a path list as a security prompt. So the folders where a file
/// name alone is enough to do harm can't be chosen at all.
public enum SaveLocation {

    /// Why `folder` can't hold downloads, or nil when it can.
    public static func refusal(for folder: URL, home: URL) -> String? {
        let path = folder.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path

        if path == "/" || path == "/Users" || path == "/Volumes" {
            return "Downloads can't go at the top of a disk. Choose or create a folder inside it."
        }
        if path == homePath {
            return "Your home folder holds your settings and startup files, and a download could replace them. Choose or create a folder inside it."
        }
        if path == homePath + "/Library" || path.hasPrefix(homePath + "/Library/") {
            return "The Library folder holds settings apps run from. Choose a folder outside it."
        }
        for system in ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private/etc"]
        where path == system || path.hasPrefix(system + "/") {
            return "That's a system folder. Choose a folder of your own."
        }
        return nil
    }
}
