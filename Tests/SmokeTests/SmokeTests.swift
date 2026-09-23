import mergehawkcore

let mergehawkSmokeTest: Void = {
    precondition(NotificationPreferences.defaults.authored.comments)
    precondition(!NotificationPreferences.defaults.authored.relationshipChanges)
    precondition(!NotificationPreferences.defaults.assigned.comments)
    precondition(NotificationPreferences.defaults.assigned.relationshipChanges)
}()
