import Foundation

enum WelcomeGreeting: Equatable, Sendable {
    case morning, afternoon, evening, welcomeBack

    /// A short absence is a return, not a new part of the day.
    static let returnThreshold = Duration.seconds(60 * 60)

    static func resolve(hour: Int, awayFor: Duration?) -> WelcomeGreeting {
        if let awayFor, awayFor < returnThreshold { return .welcomeBack }
        return switch hour {
        case 5..<12: .morning
        case 12..<18: .afternoon
        default: .evening
        }
    }

    /// The first preferred language Morph has words for. The rest of Morph is in English, so
    /// that's the fallback.
    func text(languages: [String] = Locale.preferredLanguages) -> String {
        let code = languages.lazy.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            .first { Self.table[$0] != nil } ?? "en"
        let words = Self.table[code] ?? Self.table["en"]!
        return switch self {
        case .morning: words[0]
        case .afternoon: words[1]
        case .evening: words[2]
        case .welcomeBack: words[3]
        }
    }

    private static let table: [String: [String]] = [
        "en": ["Good morning", "Good afternoon", "Good evening", "Welcome back"],
        "pt": ["Bom dia", "Boa tarde", "Boa noite", "Bem-vindo de volta"],
        "es": ["Buenos días", "Buenas tardes", "Buenas noches", "Bienvenido de nuevo"],
        "fr": ["Bonjour", "Bon après-midi", "Bonsoir", "Bon retour"],
    ]
}

/// What the island says after an unlock. Built once, at the moment of the unlock, so nothing in
/// it can be from before the lock.
struct WelcomeContent: Equatable, Sendable {
    struct Battery: Equatable, Sendable {
        var percentage: Int
        var isCharging: Bool
        var symbol: String
    }

    struct Music: Equatable, Sendable {
        var title: String
        var artist: String
        var isPlaying: Bool
    }

    var greeting: WelcomeGreeting
    var date: Date
    var battery: Battery?
    var music: Music?

    /// The second phase has something to say beyond the time.
    var hasDetails: Bool { battery != nil || music != nil }
}

/// The few rules for whether a return deserves a welcome.
struct WelcomePolicy: Equatable, Sendable {
    var integrationEnabled: Bool
    var welcomeEnabled: Bool
    var activitiesEnabled: Bool
    var islandIdle: Bool
    var cinemaNormal: Bool
    var currentPriority: ActivityPriority?

    func allows(_ sessionReturn: SessionReturn) -> Bool {
        guard sessionReturn.welcome, integrationEnabled, welcomeEnabled, activitiesEnabled, islandIdle, cinemaNormal else { return false }
        // Something urgent already has the island.
        if let currentPriority, currentPriority >= .high { return false }
        return true
    }
}
