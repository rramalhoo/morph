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

/// A battery somewhere other than the Mac, as read from the system.
struct PeripheralReading: Equatable, Sendable {
    var name: String
    var percentage: Int?
    var isCharging: Bool?
}

/// One row of the Battery panel. No value means no reliable value: nothing here is estimated.
struct PowerDevice: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case mac, audio(symbol: String), keyboard, mouse, trackpad, other
    }

    var id: String
    var name: String
    var kind: Kind
    var percentage: Int?
    var isCharging: Bool?
    /// What's known when there's no percentage, or alongside it.
    var status: String

    var symbol: String {
        switch kind {
        case .mac: "laptopcomputer"
        case .audio(let symbol): symbol
        case .keyboard: "keyboard"
        case .mouse: "magicmouse"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    static func kind(named name: String) -> Kind {
        let lowered = name.lowercased()
        if lowered.contains("keyboard") { return .keyboard }
        if lowered.contains("trackpad") { return .trackpad }
        if lowered.contains("mouse") { return .mouse }
        return .other
    }

    /// The Mac first, then audio, then everything else by name. A device reachable both as audio
    /// and as a power source appears once, with the battery the system reports for that exact name.
    static func list(mac: BatterySnapshot?, audio: [AudioOutputDevice], currentOutputUID: String?,
                     peripherals: [PeripheralReading], showsAudio: Bool, showsPeripherals: Bool) -> [PowerDevice] {
        var rows: [PowerDevice] = []
        if let mac {
            rows.append(PowerDevice(id: "mac", name: "This Mac", kind: .mac, percentage: mac.percentage,
                                    isCharging: mac.isCharging, status: mac.statusText))
        }
        var claimed = Set<String>()
        if showsAudio {
            for device in audio {
                let reading = showsPeripherals ? peripherals.first { $0.name == device.name } : nil
                if reading != nil { claimed.insert(device.name) }
                rows.append(PowerDevice(id: device.uid, name: device.name, kind: .audio(symbol: device.symbol),
                                        percentage: reading?.percentage, isCharging: reading?.isCharging,
                                        status: device.uid == currentOutputUID ? "Connected, audio output" : "Connected"))
            }
        }
        if showsPeripherals {
            let others = peripherals.filter { !claimed.contains($0.name) }.sorted { $0.name < $1.name }
            rows += others.map { reading in
                PowerDevice(id: "peripheral-\(reading.name)", name: reading.name, kind: kind(named: reading.name),
                            percentage: reading.percentage, isCharging: reading.isCharging,
                            status: reading.isCharging == true ? "Charging" : "Connected")
            }
        }
        return rows
    }
}

/// Warns once per discharge for each device, like the Mac's own low battery alert.
struct PeripheralAlertTracker: Sendable {
    private var alerted = Set<String>()

    mutating func process(_ readings: [PeripheralReading], threshold: Int) -> [PeripheralReading] {
        var due: [PeripheralReading] = []
        for reading in readings {
            guard let percentage = reading.percentage else { continue }
            if percentage > threshold || reading.isCharging == true {
                alerted.remove(reading.name)
            } else if alerted.insert(reading.name).inserted {
                due.append(reading)
            }
        }
        return due
    }
}
