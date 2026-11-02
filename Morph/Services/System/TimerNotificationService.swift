import Foundation
@preconcurrency import UserNotifications

/// Optional system notification for a finished timer, for when the island is out of sight.
struct TimerNotificationService: Sendable {
    private static let identifier = "com.athene.morph.timer"

    func schedule(after remaining: Duration) {
        let center = UNUserNotificationCenter.current()
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Timer finished"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, remaining.timeInterval), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
        }
    }

    func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.identifier])
    }
}
