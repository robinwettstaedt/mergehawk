import test from "node:test";
import assert from "node:assert/strict";
import { createGitHubClient } from "../src/main/githubClient.mjs";

test("fetches pull requests through GitHub GraphQL search", async () => {
  const requests = [];
  const client = createGitHubClient({
    token: "gho_test",
    fetcher: async (url, options) => {
      requests.push({ url, options });
      return {
        ok: true,
        json: async () => ({
          data: {
            search: {
              nodes: [
                {
                  id: "PR_1",
                  title: "Ship dashboard",
                  number: 12,
                  url: "https://github.com/acme/vc-dash/pull/12",
                  isDraft: false,
                  mergeable: "MERGEABLE",
                  reviewDecision: "REVIEW_REQUIRED",
                  comments: { totalCount: 2 },
                  reviews: { totalCount: 1 },
                  repository: { nameWithOwner: "acme/vc-dash" },
                  commits: {
                    nodes: [
                      {
                        commit: {
                          statusCheckRollup: { state: "FAILURE" }
                        }
                      }
                    ]
                  },
                  author: { login: "rw" }
                }
              ]
            }
          }
        })
      };
    }
  });

  const pullRequests = await client.fetchPullRequests({ login: "rw" });

  assert.equal(requests[0].url, "https://api.github.com/graphql");
  assert.equal(requests[0].options.headers.authorization, "Bearer gho_test");
  assert.equal(JSON.parse(requests[0].options.body).variables.query.includes("author:rw"), true);
  assert.deepEqual(pullRequests, [
    {
      id: "PR_1",
      title: "Ship dashboard",
      number: 12,
      url: "https://github.com/acme/vc-dash/pull/12",
      repo: "acme/vc-dash",
      ciState: "failing",
      reviewDecision: "review_required",
      commentCount: 2,
      reviewCount: 1,
      isMine: true,
      author: "rw",
      mergeable: "mergeable",
      draft: false
    }
  ]);
});
