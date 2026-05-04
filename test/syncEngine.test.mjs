import test from "node:test";
import assert from "node:assert/strict";
import { createSyncEngine } from "../src/main/syncEngine.mjs";

test("sync baselines first fetch and reports PRs", async () => {
  const engine = createSyncEngine({
    fetchPullRequests: async () => [
      {
        id: "1",
        title: "Build tray app",
        repo: "acme/vc-dash",
        ciState: "passing",
        reviewDecision: "review_required",
        commentCount: 0,
        reviewCount: 0,
        isMine: true
      }
    ]
  });

  const result = await engine.sync();

  assert.equal(result.pullRequests.length, 1);
  assert.deepEqual(result.events, []);
});

test("sync emits filtered events after baseline", async () => {
  const snapshots = [
    [
      {
        id: "1",
        title: "Build tray app",
        repo: "acme/vc-dash",
        ciState: "passing",
        reviewDecision: "review_required",
        commentCount: 0,
        reviewCount: 0,
        isMine: true
      }
    ],
    [
      {
        id: "1",
        title: "Build tray app",
        repo: "acme/vc-dash",
        ciState: "failing",
        reviewDecision: "review_required",
        commentCount: 1,
        reviewCount: 0,
        isMine: true
      }
    ]
  ];

  const engine = createSyncEngine({
    fetchPullRequests: async () => snapshots.shift()
  });

  await engine.sync();
  const result = await engine.sync();

  assert.deepEqual(
    result.events.map((event) => event.type),
    ["new_comment", "ci_failed"]
  );
});
