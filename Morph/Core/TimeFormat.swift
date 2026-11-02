import Foundation

enum TimeFormat {
    /// `1:05`, `12:30` or `1:02:03`.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Countdown display rounds up, so a timer shows `1:00` for its whole first second.
    static func countdown(_ seconds: TimeInterval) -> String {
        clock(seconds.rounded(.up))
    }

    /// Stopwatch display with tenths: `0:07.4`.
    static func stopwatch(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let tenths = Int((clamped * 10).rounded(.down)) % 10
        return "\(clock(clamped)).\(tenths)"
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
