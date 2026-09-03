import Foundation
import CurrentCore

/// Turns drops, pastes, and URL events into things the engine can add.
public enum DropParser {

    public enum Parsed: Equatable {
        case magnet(String)
        case torrentFile(URL)
    }

    /// One URL handed over by the system: a magnet link clicked in a browser,
    /// or a `.torrent` dropped on the app icon.
    ///
    /// The scheme is compared case-insensitively because URL schemes *are*
    /// case-insensitive, and a `MAGNET:` link — which some sites really do
    /// produce — used to be silently ignored by a `hasPrefix("magnet:")` check.
    ///
    /// Anything else returns nil, and the caller ignores it without comment.
    /// The app is registered for exactly these two things, so a third would
    /// mean the system got it wrong; a dialog about that would be noise.
    ///
    /// This is classification, not validation: a malformed magnet still counts
    /// as a magnet, because the engine is what knows whether it can be parsed
    /// and it already reports that properly.
    public static func parse(url: URL) -> Parsed? {
        if url.scheme?.lowercased() == "magnet" {
            return .magnet(url.absoluteString)
        }
        if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
            return .torrentFile(url)
        }
        return nil
    }

    public static func parse(fileURLs: [URL]) -> [Parsed] {
        fileURLs
            .filter { $0.pathExtension.lowercased() == "torrent" }
            .map(Parsed.torrentFile)
    }

    /// Extracts every magnet link from arbitrary text.
    public static func magnets(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "magnet:[^\\s\\x22\\x27<>]+") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    public static func parse(pasteboard strings: [String], urls: [URL] = []) -> [Parsed] {
        var results: [Parsed] = []
        for string in strings where string.hasPrefix("magnet:") {
            results.append(.magnet(string))
        }
        if results.isEmpty {
            for text in strings {
                results.append(contentsOf: magnets(in: text).map(Parsed.magnet))
            }
        }
        for url in urls where url.absoluteString.hasPrefix("magnet:") {
            results.append(.magnet(url.absoluteString))
        }
        results.append(contentsOf: parse(fileURLs: urls))
        return results
    }

    /// The display name a magnet carries in its `dn=` parameter.
    ///
    /// `+` becomes a space before percent-decoding, because `dn` is a query
    /// parameter and that is what `+` means in one. Without it, a magnet from
    /// almost any site showed up in the library as
    /// `Some.Release+Name+Here` — decoded, but still wearing its plus signs.
    /// A literal plus in a name is collateral damage, and every other client
    /// makes the same trade.
    public static func nameHint(fromMagnet uri: String) -> String? {
        guard let range = uri.range(of: "dn=") else { return nil }
        let tail = String(uri[range.upperBound...])
        let token = tail.split(separator: "&").first.map(String.init) ?? tail
        let spaced = token.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
