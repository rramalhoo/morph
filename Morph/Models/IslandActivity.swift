import Foundation

/// Ordered lowest first. A higher priority interrupts a lower one.
enum ActivityPriority: Int, Comparable, Sendable {
    /// Dropped rather than interrupting anything.
    case low
    case music
    case normal
    /// From here up, an activity may appear while the user is hovering.
    case timer
    case device
    /// Volume and brightness: direct feedback for something the user just did.
    case level
    case high
    /// Shown even inside the expanded panel.
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum ActivityPresentation: Equatable, Sendable {
    /// Fits in the ears either side of the notch.
    case minimal
    /// Grows below the notch for a title and subtitle.
    case banner
    /// The volume and brightness HUD.
    case level
}

enum ActivityDismissal: Equatable, Sendable {
    case automatic
    /// Stays up until acknowledged, or until `duration` runs out as a safety net.
    case acknowledge
}

/// One transient thing the island wants to say.
struct IslandActivity: Identifiable, Equatable, Sendable {
    /// How long a level HUD eases off before the island closes. Follows the hold time.
    static let levelFade = Duration.milliseconds(280)
    static let levelHold = Duration.milliseconds(1200)

    enum Content: Equatable, Sendable {
        case powerConnected(percentage: Int, charging: Bool)
        case powerDisconnected(percentage: Int)
        case fullyCharged
        case batteryLow(percentage: Int)
        case batteryCritical(percentage: Int)
        case nowPlaying(title: String, artist: String)
        case timerCompleted(duration: TimeInterval)
        case filesAdded(count: Int)
        /// The player's own volume, changed from Morph.
        case volumeChanged(percentage: Int)
        /// The system output, as reported by its driver.
        case outputVolume(percentage: Int, muted: Bool)
        /// `percentage` is present only where a public API can read it.
        case brightness(increased: Bool, percentage: Int?)
        case deviceConnected(name: String, symbol: String, battery: Int?)
        case deviceDisconnected(name: String, symbol: String)
        case outputChanged(name: String, symbol: String)
        case trackSkipped(forward: Bool)
        case actionFailed(message: String)
    }

    let id: UUID
    var content: Content
    var priority: ActivityPriority
    var presentation: ActivityPresentation
    var duration: Duration
    var dismissal: ActivityDismissal
    var timestamp: ContinuousClock.Instant
    /// Activities sharing a key replace each other rather than stacking up.
    var dedupeKey: String
    /// Whether it returns to the queue after a higher priority interruption.
    var resumesAfterInterruption: Bool
    /// How long it may wait in the queue before it is no longer worth showing.
    var maximumWait: Duration

    init(_ content: Content, at timestamp: ContinuousClock.Instant, id: UUID = UUID()) {
        self.id = id
        self.content = content
        self.timestamp = timestamp

        switch content {
        case .powerConnected, .powerDisconnected:
            (priority, presentation, duration) = (.normal, .minimal, .seconds(3))
            (dismissal, dedupeKey) = (.automatic, "power")
            (resumesAfterInterruption, maximumWait) = (false, .seconds(5))
        case .fullyCharged:
            (priority, presentation, duration) = (.normal, .banner, .seconds(4))
            (dismissal, dedupeKey) = (.automatic, "power")
            (resumesAfterInterruption, maximumWait) = (true, .seconds(30))
        case .batteryLow:
            (priority, presentation, duration) = (.high, .banner, .seconds(6))
            (dismissal, dedupeKey) = (.automatic, "battery-alert")
            (resumesAfterInterruption, maximumWait) = (true, .seconds(120))
        case .batteryCritical:
            (priority, presentation, duration) = (.critical, .banner, .seconds(20))
            (dismissal, dedupeKey) = (.acknowledge, "battery-alert")
            (resumesAfterInterruption, maximumWait) = (true, .seconds(300))
        case .nowPlaying:
            (priority, presentation, duration) = (.music, .minimal, .seconds(3))
            (dismissal, dedupeKey) = (.automatic, "now-playing")
            (resumesAfterInterruption, maximumWait) = (false, .seconds(4))
        case .timerCompleted:
            (priority, presentation, duration) = (.timer, .banner, .seconds(30))
            (dismissal, dedupeKey) = (.acknowledge, "timer")
            (resumesAfterInterruption, maximumWait) = (true, .seconds(300))
        case .filesAdded:
            (priority, presentation, duration) = (.normal, .minimal, .seconds(2))
            (dismissal, dedupeKey) = (.automatic, "files")
            (resumesAfterInterruption, maximumWait) = (false, .seconds(5))
        case .volumeChanged, .outputVolume, .brightness:
            // One key shared by all levels, so successive changes update a single activity in place.
            (priority, presentation, duration) = (.level, .level, Self.levelHold + Self.levelFade)
            (dismissal, dedupeKey) = (.automatic, "level")
            (resumesAfterInterruption, maximumWait) = (false, .seconds(1))
        case .deviceConnected, .deviceDisconnected, .outputChanged:
            (priority, presentation, duration) = (.device, .banner, .seconds(3))
            (dismissal, dedupeKey) = (.automatic, "device")
            (resumesAfterInterruption, maximumWait) = (false, .seconds(8))
        case .trackSkipped:
            (priority, presentation, duration) = (.music, .minimal, .milliseconds(1200))
            (dismissal, dedupeKey) = (.automatic, "now-playing")
            (resumesAfterInterruption, maximumWait) = (false, .seconds(1))
        case .actionFailed:
            (priority, presentation, duration) = (.normal, .banner, .seconds(4))
            (dismissal, dedupeKey) = (.automatic, "action-failed")
            (resumesAfterInterruption, maximumWait) = (false, .seconds(5))
        }
    }
}

/// Icon and copy for an activity, shared by the island and the Recent list.
extension IslandActivity.Content {
    var symbol: String {
        switch self {
        case .powerConnected(_, let charging): charging ? "bolt.fill" : "powerplug.fill"
        case .powerDisconnected: "powerplug"
        case .fullyCharged: "battery.100percent.bolt"
        case .batteryLow: "battery.25percent"
        case .batteryCritical: "battery.0percent"
        case .nowPlaying: "music.note"
        case .timerCompleted: "timer"
        case .filesAdded: "tray.and.arrow.down.fill"
        case .volumeChanged(let percentage): Self.speakerSymbol(percentage: percentage, muted: false)
        case .outputVolume(let percentage, let muted): Self.speakerSymbol(percentage: percentage, muted: muted)
        case .brightness(let increased, _): increased ? "sun.max.fill" : "sun.min.fill"
        case .deviceConnected(_, let symbol, _), .deviceDisconnected(_, let symbol), .outputChanged(_, let symbol): symbol
        case .trackSkipped(let forward): forward ? "forward.fill" : "backward.fill"
        case .actionFailed: "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .powerConnected(_, let charging): charging ? "Charging" : "Power connected"
        case .powerDisconnected: "On battery"
        case .fullyCharged: "Fully charged"
        case .batteryLow: "Battery low"
        case .batteryCritical: "Battery critical"
        case .nowPlaying(let title, _): title
        case .timerCompleted: "Timer finished"
        case .filesAdded(let count): count == 1 ? "1 file added" : "\(count) files added"
        case .volumeChanged, .outputVolume: "Volume"
        case .brightness(let increased, _): increased ? "Brighter" : "Dimmer"
        case .deviceConnected(let name, _, _): "\(name) connected"
        case .deviceDisconnected(let name, _): "\(name) disconnected"
        case .outputChanged(let name, _): name
        case .trackSkipped(let forward): forward ? "Next" : "Previous"
        case .actionFailed: "Couldn't do that"
        }
    }

    var subtitle: String? {
        switch self {
        case .powerConnected(let percentage, _), .powerDisconnected(let percentage): "\(percentage)%"
        case .fullyCharged: "Running on power adapter"
        case .batteryLow(let percentage): "\(percentage)% remaining"
        case .batteryCritical(let percentage): "\(percentage)% remaining. Connect power soon."
        case .nowPlaying(_, let artist): artist.isEmpty ? nil : artist
        case .timerCompleted(let duration): TimeFormat.clock(duration)
        case .filesAdded: nil
        case .volumeChanged(let percentage): "\(percentage)%"
        case .outputVolume(let percentage, let muted): muted ? "Muted" : "\(percentage)%"
        case .brightness(_, let percentage): percentage.map { "\($0)%" }
        case .deviceConnected(_, _, let battery): battery.map { "Battery \($0)%" }
        case .deviceDisconnected, .trackSkipped: nil
        case .outputChanged: "Audio output"
        case .actionFailed(let message): message
        }
    }
}

/// Volume and brightness keep separate state and share one presentation.
enum LevelKind: Equatable, Sendable {
    case volume, brightness
}

extension IslandActivity.Content {
    var levelKind: LevelKind? {
        switch self {
        case .volumeChanged, .outputVolume: .volume
        case .brightness: .brightness
        default: nil
        }
    }

    /// One symbol per kind where possible, so the waves can fill in rather than swap.
    var levelSymbol: String {
        switch self {
        case .volumeChanged(let percentage) where percentage > 0: "speaker.wave.3.fill"
        case .outputVolume(let percentage, false) where percentage > 0: "speaker.wave.3.fill"
        case .brightness(_, let percentage?): percentage >= 50 ? "sun.max.fill" : "sun.min.fill"
        default: symbol
        }
    }

    var isMuted: Bool {
        if case .outputVolume(_, true) = self { true } else { false }
    }

    /// A value shown as a bar. Absent when there's no real reading to draw.
    var level: Double? {
        switch self {
        case .volumeChanged(let percentage): Double(percentage) / 100
        case .outputVolume(let percentage, let muted): muted ? 0 : Double(percentage) / 100
        case .brightness(_, let percentage): percentage.map { Double($0) / 100 }
        default: nil
        }
    }

    /// Feedback for an action in progress isn't history.
    var appearsInRecent: Bool {
        switch self {
        case .volumeChanged, .outputVolume, .brightness, .trackSkipped: false
        default: true
        }
    }

    private static func speakerSymbol(percentage: Int, muted: Bool) -> String {
        if muted { return "speaker.slash.fill" }
        return switch percentage {
        case 0: "speaker.fill"
        case ..<34: "speaker.wave.1.fill"
        case ..<67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}

/// A presented activity kept for the Recent list.
struct ActivityRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let content: IslandActivity.Content
    let date: Date
}
