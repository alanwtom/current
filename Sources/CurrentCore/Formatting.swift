import Foundation

public enum ByteFormatting {
    private static let units: [String] = ["B", "KB", "MB", "GB", "TB", "PB"]

    public static func bytes(_ value: Int64, precision: Int? = nil) -> String {
        guard value > 0 else { return "0 B" }
        let exponent = min(Int(log2(Double(value)) / 10), units.count - 1)
        let scaled = Double(value) / pow(1024, Double(exponent))
        let digits: Int
        if let precision {
            digits = precision
        } else if scaled >= 100 {
            digits = 0
        } else if scaled >= 10 {
            digits = 1
        } else {
            digits = 1
        }
        return String(format: "%.\(digits)f %@", scaled, units[exponent])
    }

    public static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0.5 else { return "—" }
        return "\(bytes(Int64(bytesPerSecond)))/s"
    }

    public static func progress(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Compact duration: `3 min`, `2 d 6 h`, `45 s`.
    public static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let interval = Int(seconds.rounded())
        if interval < 60 { return "\(interval)s" }
        if interval < 3600 {
            let minutes = (interval + 30) / 60
            return "\(minutes) min"
        }
        if interval < 86_400 {
            let hours = interval / 3600
            let minutes = (interval % 3600) / 1800
            if minutes == 0 { return "\(hours) hr" }
            return "\(hours).5 hr"
        }
        let days = interval / 86_400
        let hours = (interval % 86_400) / 3600
        if hours == 0 { return "\(days)d" }
        return "\(days)d \(hours)h"
    }

    /// Long-form duration for rule explanations: `2d 6h`, `24h`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let interval = max(0, Int(seconds))
        if interval < 60 { return "\(interval)s" }
        if interval < 3600 { return "\(interval / 60)m" }
        if interval < 86_400 {
            let h = interval / 3600
            let m = (interval % 3600) / 60
            return m == 0 ? "\(h)h" : "\(h)h \(m)m"
        }
        let d = interval / 86_400
        let h = (interval % 86_400) / 3600
        return h == 0 ? "\(d)d" : "\(d)d \(h)h"
    }

    public static func ratio(_ value: Double) -> String {
        if value.isInfinite { return "∞" }
        return String(format: "%.2f×", value)
    }
}
