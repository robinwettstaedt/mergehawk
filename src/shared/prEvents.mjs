export const defaultNotificationPreferences = {
  new_comment: true,
  new_review: true,
  ci_failed: true,
  changes_requested: true,
  ready_to_merge: true,
  review_requested: false,
  assigned: false,
  ci_passed: false
};

export function detectPrEvents({ previous, current }) {
  if (!previous) {
    return [];
  }

  const events = [];

  if (current.commentCount > previous.commentCount) {
    events.push({
      type: "new_comment",
      prId: current.id,
      count: current.commentCount - previous.commentCount
    });
  }

  if (current.reviewCount > previous.reviewCount) {
    events.push({
      type: "new_review",
      prId: current.id,
      count: current.reviewCount - previous.reviewCount
    });
  }

  if (current.isMine && previous.ciState !== "failing" && current.ciState === "failing") {
    events.push({
      type: "ci_failed",
      prId: current.id
    });
  }

  if (
    current.isMine &&
    previous.reviewDecision !== "changes_requested" &&
    current.reviewDecision === "changes_requested"
  ) {
    events.push({
      type: "changes_requested",
      prId: current.id
    });
  }

  return events;
}

export function filterPrEvents(events, preferences) {
  return events.filter((event) => preferences[event.type] === true);
}
