import Foundation

struct BatterySnapshot: Equatable, Sendable {
    var percentage: Int
    var isCharging: Bool
    var isOnExternalPower: Bool
    var isCharged: Bool
    /// Minutes, when macOS has finished estimating.
    var minutesToEmpty: Int?
    var minutesToFull: Int?

    var symbol: String {
        if isCharging || isOnExternalPower { return "battery.100percent.bolt" }
        return switch percentage {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    var statusText: String {
        if isCharged { return "Charged" }
        if isCharging {
            return minutesToFull.map { "\(Self.format($0)) until full" } ?? "Charging"
        }
        if isOnExternalPower { return "Not charging" }
        return minutesToEmpty.map { "\(Self.format($0)) left" } ?? "On battery"
    }

    private static func format(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

enum BatteryEvent: Equatable, Sendable {
    case powerConnected(percentage: Int, charging: Bool)
    case powerDisconnected(percentage: Int)
    case fullyCharged
    case low(percentage: Int)
    case critical(percentage: Int)
}

/// Turns a stream of snapshots into discrete events. Each alert fires once per discharge.
struct BatteryTransitionDetector: Sendable {
    static let criticalThreshold = 5

    var lowThreshold: Int
    private var previous: BatterySnapshot?
    private var lowFired = false
    private var criticalFired = false

    init(lowThreshold: Int = 20) {
        self.lowThreshold = lowThreshold
    }

    mutating func process(_ snapshot: BatterySnapshot) -> [BatteryEvent] {
        defer { previous = snapshot }

        if snapshot.isOnExternalPower {
            lowFired = false
            criticalFired = false
        }

        guard let previous else {
            // Launching at low battery still warrants a warning, but not a "power connected".
            return alerts(for: snapshot)
        }

        var events: [BatteryEvent] = []
        if snapshot.isOnExternalPower && !previous.isOnExternalPower {
            events.append(.powerConnected(percentage: snapshot.percentage, charging: snapshot.isCharging))
        } else if !snapshot.isOnExternalPower && previous.isOnExternalPower {
            events.append(.powerDisconnected(percentage: snapshot.percentage))
        }
        if snapshot.isCharged && !previous.isCharged && snapshot.isOnExternalPower {
            events.append(.fullyCharged)
        }
        return events + alerts(for: snapshot)
    }

    private mutating func alerts(for snapshot: BatterySnapshot) -> [BatteryEvent] {
        guard !snapshot.isOnExternalPower else { return [] }
        if snapshot.percentage <= Self.criticalThreshold, !criticalFired {
            criticalFired = true
            lowFired = true
            return [.critical(percentage: snapshot.percentage)]
        }
        if snapshot.percentage <= lowThreshold, !lowFired {
            lowFired = true
            return [.low(percentage: snapshot.percentage)]
        }
        return []
    }
}
