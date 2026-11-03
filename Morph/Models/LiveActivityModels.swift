import Foundation

/// An activity another app asked Morph to show. Everything in it has been validated.
struct ExternalActivity: Identifiable, Equatable, Sendable {
    enum State: String, Codable, CaseIterable, Sendable {
        case running, paused, success, failed
    }

    /// What the sender would like. It only orders activities among themselves: the effective
    /// priority is always `ActivityPriority.liveActivity`, so nothing here can reach an alert.
    enum RequestedPriority: String, Codable, CaseIterable, Sendable {
        case low, normal, high

        var rank: Int {
            switch self {
            case .low: 0
            case .normal: 1
            case .high: 2
            }
        }
    }

    let id: String
    var title: String
    var subtitle: String?
    var symbol: String
    var progress: Double?
    var state: State
    var requestedPriority: RequestedPriority
    var expiresAt: ContinuousClock.Instant
}

enum LiveActivityLimits {
    static let version = 1
    static let maximumBody = 4 * 1024
    static let maximumHeaders = 8 * 1024
    static let maximumActive = 8
    static let maximumIDLength = 64
    static let maximumTitleLength = 80
    static let maximumSubtitleLength = 120
    static let durationRange = 1...3600
    static let defaultDuration = 300
    /// Requests per second sustained, and the burst allowed on top.
    static let requestRate = 10.0
    static let requestBurst = 30.0
    /// Failed authorizations allowed, refilled at one every six seconds.
    static let failureBurst = 10.0
    static let failureRate = 1.0 / 6

    /// SF Symbols by short name. A sender can't name an arbitrary symbol or image.
    static let icons: [String: String] = [
        "activity": "dot.radiowaves.left.and.right",
        "arrow.down": "arrow.down.circle.fill",
        "arrow.up": "arrow.up.circle.fill",
        "bell": "bell.fill",
        "build": "hammer.fill",
        "camera": "camera.fill",
        "check": "checkmark.circle.fill",
        "cloud": "cloud.fill",
        "code": "chevron.left.forwardslash.chevron.right",
        "cpu": "cpu.fill",
        "doc": "doc.fill",
        "error": "xmark.octagon.fill",
        "terminal": "terminal.fill",
        "timer": "timer",
        "tray": "tray.full.fill",
        "warning": "exclamationmark.triangle.fill",
    ]
}

enum LiveActivityValidationError: Error, Equatable {
    case malformed
    case unknownField(String)
    case invalid(String)

    var message: String {
        switch self {
        case .malformed: "The body must be a JSON object"
        case .unknownField(let name): "Unknown field: \(name)"
        case .invalid(let reason): reason
        }
    }
}

/// A create or update body, checked field by field. On an update, absent fields keep their value.
struct LiveActivityPayload: Equatable, Sendable {
    private static let fields: Set<String> = ["id", "title", "subtitle", "icon", "progress", "duration", "priority", "state"]
    private static let idCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))

    var id: String?
    var title: String?
    var subtitle: String?
    var symbol: String?
    var progress: Double?
    var duration: Int?
    var priority: ExternalActivity.RequestedPriority?
    var state: ExternalActivity.State?

    init(json data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LiveActivityValidationError.malformed
        }
        if let unknown = object.keys.sorted().first(where: { !Self.fields.contains($0) }) {
            throw LiveActivityValidationError.unknownField(unknown)
        }
        id = try Self.string(object, "id", limit: LiveActivityLimits.maximumIDLength)
        title = try Self.string(object, "title", limit: LiveActivityLimits.maximumTitleLength)
        subtitle = try Self.string(object, "subtitle", limit: LiveActivityLimits.maximumSubtitleLength)

        if let id, id.isEmpty || id.unicodeScalars.contains(where: { !Self.idCharacters.contains($0) || !$0.isASCII }) {
            throw LiveActivityValidationError.invalid("id may only hold letters, digits, dots, dashes and underscores")
        }
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LiveActivityValidationError.invalid("title can't be empty")
        }
        if let icon = object["icon"] {
            guard let name = icon as? String, let symbol = LiveActivityLimits.icons[name] else {
                throw LiveActivityValidationError.invalid("icon must be one listed by /v1/capabilities")
            }
            self.symbol = symbol
        }
        if let value = object["progress"] {
            guard let number = Self.number(value), number.isFinite, (0...1).contains(number) else {
                throw LiveActivityValidationError.invalid("progress must be a number from 0 to 1")
            }
            progress = number
        }
        if let value = object["duration"] {
            guard let number = Self.number(value), number.isFinite, number == number.rounded(),
                  LiveActivityLimits.durationRange.contains(Int(number)) else {
                throw LiveActivityValidationError.invalid("duration must be a whole number of seconds from 1 to 3600")
            }
            duration = Int(number)
        }
        priority = try Self.option(object, "priority")
        state = try Self.option(object, "state")
    }

    private static func string(_ object: [String: Any], _ key: String, limit: Int) throws -> String? {
        guard let value = object[key] else { return nil }
        guard let text = value as? String else { throw LiveActivityValidationError.invalid("\(key) must be text") }
        guard text.count <= limit else { throw LiveActivityValidationError.invalid("\(key) can be \(limit) characters at most") }
        // Control characters could break the single line it's shown on.
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LiveActivityValidationError.invalid("\(key) can't hold control characters")
        }
        return text
    }

    /// JSON booleans also arrive as `NSNumber`, and aren't numbers here.
    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private static func option<T: RawRepresentable>(_ object: [String: Any], _ key: String) throws -> T? where T.RawValue == String {
        guard let value = object[key] else { return nil }
        guard let raw = value as? String, let option = T(rawValue: raw) else {
            throw LiveActivityValidationError.invalid("\(key) has an unknown value")
        }
        return option
    }
}
