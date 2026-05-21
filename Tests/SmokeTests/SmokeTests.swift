import mergehawkcore

let mergehawkSmokeTest: Void = {
    precondition(NotificationPreferences.defaults.authored.comments)
    precondition(!NotificationPreferences.defaults.assigned.comments)
}()
