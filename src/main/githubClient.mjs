const pullRequestSearchQuery = `
  query PullRequestDashboard($query: String!) {
    search(query: $query, type: ISSUE, first: 50) {
      nodes {
        ... on PullRequest {
          id
          title
          number
          url
          isDraft
          mergeable
          reviewDecision
          comments {
            totalCount
          }
          reviews {
            totalCount
          }
          repository {
            nameWithOwner
          }
          commits(last: 1) {
            nodes {
              commit {
                statusCheckRollup {
                  state
                }
              }
            }
          }
          author {
            login
          }
        }
      }
    }
  }
`;

export function createGitHubClient({ token, fetcher = fetch }) {
  async function graphql(query, variables) {
    const response = await fetcher("https://api.github.com/graphql", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json"
      },
      body: JSON.stringify({ query, variables })
    });

    if (!response.ok) {
      throw new Error(`GitHub GraphQL request failed with status ${response.status}`);
    }

    const payload = await response.json();
    if (payload.errors?.length) {
      throw new Error(payload.errors.map((error) => error.message).join("; "));
    }

    return payload.data;
  }

  async function fetchPullRequests({ login }) {
    const query = `is:open is:pr author:${login} assignee:${login} user-review-requested:${login}`;
    const data = await graphql(pullRequestSearchQuery, { query });
    return data.search.nodes.map((node) => normalizePullRequest(node, login));
  }

  return {
    fetchPullRequests
  };
}

function normalizePullRequest(node, login) {
  const rollupState = node.commits?.nodes?.[0]?.commit?.statusCheckRollup?.state ?? "UNKNOWN";

  return {
    id: node.id,
    title: node.title,
    number: node.number,
    url: node.url,
    repo: node.repository.nameWithOwner,
    ciState: normalizeCiState(rollupState),
    reviewDecision: normalizeReviewDecision(node.reviewDecision),
    commentCount: node.comments.totalCount,
    reviewCount: node.reviews.totalCount,
    isMine: node.author?.login === login,
    author: node.author?.login ?? "unknown",
    mergeable: String(node.mergeable ?? "UNKNOWN").toLowerCase(),
    draft: node.isDraft
  };
}

function normalizeCiState(state) {
  switch (state) {
    case "SUCCESS":
      return "passing";
    case "FAILURE":
    case "ERROR":
      return "failing";
    case "PENDING":
    case "EXPECTED":
      return "pending";
    default:
      return "unknown";
  }
}

function normalizeReviewDecision(decision) {
  return String(decision ?? "REVIEW_REQUIRED").toLowerCase();
}
