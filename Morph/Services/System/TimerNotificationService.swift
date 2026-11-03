import Foundation
@preconcurrency import UserNotifications

/// Optional system notification for a finished timer, for when the island is out of sight.
struct TimerNotificationService: Sendable {
    private let identifier: String
    private let title: String

    init(identifier: String = "com.athene.morph.timer", title: String = "Timer finished") {
        self.identifier = identifier
        self.title = title
    }

    func schedule(after remaining: Duration, title override: String? = nil) {
        let (identifier, title) = (identifier, override ?? title)
        let center = UNUserNotificationCenter.current()
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, remaining.timeInterval), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }

    func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}
