import mergehawkcore

let mergehawkSmokeTest: Void = {
    precondition(NotificationPreferences.defaults.commentModes.authored == .all)
    precondition(!NotificationPreferences.defaults.authored.relationshipChanges)
    precondition(NotificationPreferences.defaults.commentModes.directReviewRequests == .mentionsAndThreads)
    precondition(NotificationPreferences.defaults.assigned.relationshipChanges)
}()
