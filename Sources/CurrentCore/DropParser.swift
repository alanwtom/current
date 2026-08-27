import Foundation
import CurrentCore

/// Turns drops, pastes, and URL events into things the engine can add.
public enum DropParser {

    public enum Parsed: Equatable {
        case magnet(String)
        case torrentFile(URL)
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

    public static func nameHint(fromMagnet uri: String) -> String? {
        guard let range = uri.range(of: "dn=") else { return nil }
        let tail = String(uri[range.upperBound...])
        let token = tail.split(separator: "&").first.map(String.init) ?? tail
        return token.removingPercentEncoding
    }
}
