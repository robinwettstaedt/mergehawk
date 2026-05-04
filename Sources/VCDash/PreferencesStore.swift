import Foundation
import VCDashCore

struct PreferencesStore {
    private let defaults = UserDefaults.standard

    var notificationPreferences: NotificationPreferences {
        get {
            NotificationPreferences(
                newComment: value(for: "notifications.newComment", fallback: true),
                newReview: value(for: "notifications.newReview", fallback: true),
                ciFailed: value(for: "notifications.ciFailed", fallback: true),
                changesRequested: value(for: "notifications.changesRequested", fallback: true)
            )
        }
        set {
            defaults.set(newValue.newComment, forKey: "notifications.newComment")
            defaults.set(newValue.newReview, forKey: "notifications.newReview")
            defaults.set(newValue.ciFailed, forKey: "notifications.ciFailed")
            defaults.set(newValue.changesRequested, forKey: "notifications.changesRequested")
        }
    }

    private func value(for key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
