import {
  defaultNotificationPreferences,
  detectPrEvents,
  filterPrEvents
} from "../shared/prEvents.mjs";

export function createSyncEngine({ fetchPullRequests, preferences = defaultNotificationPreferences }) {
  const snapshots = new Map();

  async function sync() {
    const pullRequests = await fetchPullRequests();
    const events = [];

    for (const current of pullRequests) {
      const previous = snapshots.get(current.id);
      const detectedEvents = detectPrEvents({ previous, current });
      events.push(...filterPrEvents(detectedEvents, preferences));
      snapshots.set(current.id, current);
    }

    return {
      pullRequests,
      events,
      syncedAt: new Date().toISOString()
    };
  }

  return {
    sync
  };
}
