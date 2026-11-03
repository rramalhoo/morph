import Foundation
import Observation
@preconcurrency import UserNotifications

enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

/// One request as Morph sees it. The system type is built from this at the last moment.
struct NotificationRequest: Equatable, Sendable {
    var identifier: String
    var title: String
    var body: String?
    var category: String
    /// Nil delivers now.
    var delay: Duration?
}

/// The system notification center, behind a seam so the rules can be tested.
protocol NotificationCentering: Sendable {
    func authorization() async -> NotificationAuthorization
    /// Shows the system prompt only if the user hasn't decided yet.
    func requestAuthorization() async -> Bool
    func add(_ request: NotificationRequest) async -> Bool
    func remove(identifiers: [String])
}

enum NotificationKind: String, CaseIterable, Sendable {
    case timer, focus, lowBattery, deviceAlert, activity

    /// Scheduled kinds replace themselves; immediate ones wait this long before repeating.
    var minimumInterval: Duration? {
        switch self {
        case .timer, .focus: nil
        case .lowBattery, .deviceAlert: .seconds(10 * 60)
        case .activity: .seconds(30)
        }
    }
}

struct MorphNotification: Equatable, Sendable {
    var kind: NotificationKind
    var identifier: String
    var title: String
    /// Safe on any screen.
    var body: String? = nil
    /// Names a file, device or activity. Used only with previews allowed.
    var detail: String? = nil
    var delay: Duration? = nil
}

struct NotificationSettings: Equatable, Sendable {
    var enabled = true
    var previews = false
    var timer = false
    var focus = false
    var lowBattery = false
    var deviceAlerts = false
    var activities = true

    func allows(_ kind: NotificationKind) -> Bool {
        guard enabled else { return false }
        return switch kind {
        case .timer: timer
        case .focus: focus
        case .lowBattery: lowBattery
        case .deviceAlert: deviceAlerts
        case .activity: activities
        }
    }
}

enum NotificationDecision: Equatable, Sendable {
    case sent
    case disabled
    case rateLimited
    case denied
}

/// Morph's notifications: which may go out, with what words, and how often. How and where macOS
/// shows them, including on the lock screen, stays with macOS and the user's settings there.
@MainActor
@Observable
final class NotificationService {
    private(set) var authorization = NotificationAuthorization.notDetermined
    private(set) var sentCount = 0
    private(set) var droppedCount = 0

    @ObservationIgnored var settings = NotificationSettings()

    @ObservationIgnored private let center: any NotificationCentering
    @ObservationIgnored private let scheduler: any Scheduling
    @ObservationIgnored private var lastSent: [String: ContinuousClock.Instant] = [:]

    init(center: any NotificationCentering, scheduler: any Scheduling) {
        self.center = center
        self.scheduler = scheduler
    }

    /// Permissions can change in System Settings at any time without telling the app.
    func refreshAuthorization() {
        let center = center
        Task { [weak self] in
            let status = await center.authorization()
            self?.authorization = status
        }
    }

    /// From a switch the user just turned on. A denied permission isn't asked again: only
    /// System Settings can change it.
    func requestAuthorization() {
        guard authorization != .denied else { return }
        let center = center
        Task { [weak self] in
            let granted = await center.requestAuthorization()
            self?.authorization = granted ? .authorized : await center.authorization()
        }
    }

    @discardableResult
    func post(_ notification: MorphNotification) -> NotificationDecision {
        guard settings.allows(notification.kind) else { return drop(.disabled) }
        guard authorization != .denied else { return drop(.denied) }
        let key = notification.identifier
        if let interval = notification.kind.minimumInterval, let last = lastSent[key],
           last.duration(to: scheduler.now) < interval {
            return drop(.rateLimited)
        }
        lastSent[key] = scheduler.now
        sentCount += 1

        let request = NotificationRequest(identifier: key, title: notification.title,
                                          body: settings.previews ? notification.detail ?? notification.body : notification.body,
                                          category: notification.kind.rawValue, delay: notification.delay)
        let (center, needsAsking) = (center, authorization == .notDetermined)
        center.remove(identifiers: [key])
        Task { [weak self] in
            if needsAsking {
                let granted = await center.requestAuthorization()
                let status = granted ? NotificationAuthorization.authorized : await center.authorization()
                self?.authorization = status
                guard status == .authorized else { return }
            }
            _ = await center.add(request)
        }
        return .sent
    }

    func cancel(identifier: String) {
        center.remove(identifiers: [identifier])
    }

    private func drop(_ decision: NotificationDecision) -> NotificationDecision {
        droppedCount += 1
        return decision
    }
}

/// The real center. Morph is rarely the frontmost app, but when Settings is, notifications should
/// still appear rather than vanish into Notification Center.
final class SystemNotificationCenter: NSObject, NotificationCentering, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
        // With previews hidden by macOS, these show only "Morph": no title, nothing private.
        center.setNotificationCategories(Set(NotificationKind.allCases.map {
            UNNotificationCategory(identifier: $0.rawValue, actions: [], intentIdentifiers: [], options: [])
        }))
    }

    func authorization() async -> NotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .authorized
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }

    func add(_ request: NotificationRequest) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = request.title
        if let body = request.body { content.body = body }
        content.sound = .default
        content.categoryIdentifier = request.category
        content.threadIdentifier = request.category
        let trigger = request.delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeInterval), repeats: false) }
        do {
            try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
            return true
        } catch {
            return false
        }
    }

    func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
