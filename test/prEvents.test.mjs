import test from "node:test";
import assert from "node:assert/strict";
import { detectPrEvents } from "../src/shared/prEvents.mjs";

test("first sync baselines without events", () => {
  const events = detectPrEvents({
    previous: undefined,
    current: {
      id: "PR_kwDO1",
      title: "Add dashboard",
      ciState: "failing",
      reviewDecision: "changes_requested",
      commentCount: 3,
      reviewCount: 1,
      isMine: true
    }
  });

  assert.deepEqual(events, []);
});

test("detects new activity and newly failing CI on authored PR", () => {
  const events = detectPrEvents({
    previous: {
      id: "PR_kwDO1",
      title: "Add dashboard",
      ciState: "passing",
      reviewDecision: "review_required",
      commentCount: 1,
      reviewCount: 0,
      isMine: true
    },
    current: {
      id: "PR_kwDO1",
      title: "Add dashboard",
      ciState: "failing",
      reviewDecision: "changes_requested",
      commentCount: 2,
      reviewCount: 1,
      isMine: true
    }
  });

  assert.deepEqual(
    events.map((event) => event.type),
    ["new_comment", "new_review", "ci_failed", "changes_requested"]
  );
});
