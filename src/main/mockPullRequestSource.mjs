const snapshots = [
  [
    {
      id: "PR_1",
      title: "Add OAuth device flow",
      number: 14,
      url: "https://github.com/example/vc-dash/pull/14",
      repo: "example/vc-dash",
      ciState: "passing",
      reviewDecision: "review_required",
      commentCount: 2,
      reviewCount: 0,
      isMine: true,
      author: "rw",
      mergeable: "mergeable",
      draft: false
    },
    {
      id: "PR_2",
      title: "Refactor notification settings",
      number: 27,
      url: "https://github.com/example/app/pull/27",
      repo: "example/app",
      ciState: "pending",
      reviewDecision: "approved",
      commentCount: 4,
      reviewCount: 2,
      isMine: false,
      author: "teammate",
      mergeable: "unknown",
      draft: false
    }
  ],
  [
    {
      id: "PR_1",
      title: "Add OAuth device flow",
      number: 14,
      url: "https://github.com/example/vc-dash/pull/14",
      repo: "example/vc-dash",
      ciState: "failing",
      reviewDecision: "review_required",
      commentCount: 3,
      reviewCount: 0,
      isMine: true,
      author: "rw",
      mergeable: "mergeable",
      draft: false
    },
    {
      id: "PR_2",
      title: "Refactor notification settings",
      number: 27,
      url: "https://github.com/example/app/pull/27",
      repo: "example/app",
      ciState: "passing",
      reviewDecision: "approved",
      commentCount: 4,
      reviewCount: 2,
      isMine: false,
      author: "teammate",
      mergeable: "mergeable",
      draft: false
    }
  ]
];

export function createMockPullRequestSource() {
  let index = 0;

  return {
    async fetchPullRequests() {
      const snapshot = snapshots[Math.min(index, snapshots.length - 1)];
      index += 1;
      return snapshot;
    }
  };
}
