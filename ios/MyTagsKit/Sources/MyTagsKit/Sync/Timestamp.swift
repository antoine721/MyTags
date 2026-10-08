import Foundation

/// Timestamps in the API format: ISO 8601 UTC with milliseconds (`2026-10-08T12:00:00.000Z`).
///
/// The Worker rejects other formats and compares timestamps as text ("most recent wins").
public enum Timestamp {
    /// Formats a date, truncated to the millisecond.
    public static func string(from date: Date) -> String {
        let total = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        var seconds = total / 1000
        var milliseconds = total % 1000
        if milliseconds < 0 {
            seconds -= 1
            milliseconds += 1000
        }
        // "2026-10-08T12:00:00Z" without its "Z", then ".mmmZ".
        let whole = secondsStyle.format(Date(timeIntervalSince1970: TimeInterval(seconds))).dropLast()
        let digits = String(milliseconds)
        return "\(whole).\(String(repeating: "0", count: 3 - digits.count))\(digits)Z"
    }

    /// Parses an API timestamp.
    public static func date(from string: String) -> Date? {
        try? fractionalStyle.parse(string)
    }

    private static var utc: TimeZone { TimeZone(secondsFromGMT: 0) ?? .current }

    private static var secondsStyle: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZone: utc)
    }

    private static var fractionalStyle: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: utc)
    }
}
