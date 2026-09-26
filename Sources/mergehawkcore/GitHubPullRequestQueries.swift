import Foundation

enum GitHubPullRequestQueries {
    static let continuationPageSize = 100
    static let hydrationBatchSize = 20
    static let continuationBatchSize = 20

    static let completeNodeFields = """
      id
      title
      number
      url
      state
      createdAt
      updatedAt
      headRefName
      headRefOid
      isDraft
      mergeable
      additions
      deletions
      statusCheckRollup { state }
      author { login avatarUrl(size: 64) }
      repository { nameWithOwner isArchived }
      comments(last: 10) {
        totalCount
        pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
        nodes { id url createdAt viewerDidAuthor author { login __typename } }
      }
      reviews(last: 10) {
        totalCount
        pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
        nodes { id url state submittedAt viewerDidAuthor author { login __typename } }
      }
      latestOpinionatedReviews(last: 20) {
        totalCount
        pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
        nodes { id url state submittedAt viewerDidAuthor author { login __typename } }
      }
      reviewThreads(last: 20) {
        totalCount
        pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
        nodes {
          id
          isResolved
          viewerCanResolve
          comments(last: 10) {
            totalCount
            pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
            nodes {
              id url createdAt viewerDidAuthor author { login __typename }
              pullRequestReview { id }
            }
          }
        }
      }
      assignees(last: 20) {
        totalCount
        pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
        nodes { id login avatarUrl(size: 64) }
      }
      reviewRequests(last: 20) {
        totalCount
        pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
        nodes {
          id
          requestedReviewer {
            __typename
            ... on User { id login }
            ... on Team { id slug organization { login } }
          }
        }
      }
    """

    static let hydration = """
      query CompletePullRequests($ids: [ID!]!) {
        nodes(ids: $ids) {
          ... on PullRequest {
            \(completeNodeFields)
          }
        }
      }
    """

    static let discoveryBounds = """
      query DiscoveryBounds(
        $authoredOldest: String!, $authoredNewest: String!,
        $assignedOldest: String!, $assignedNewest: String!,
        $directOldest: String!, $directNewest: String!,
        $teamOldest: String!, $teamNewest: String!
      ) {
        authoredOldest: search(query: $authoredOldest, type: ISSUE, first: 1) { nodes { ...DiscoveryIdentity } }
        authoredNewest: search(query: $authoredNewest, type: ISSUE, first: 1) { nodes { ...DiscoveryIdentity } }
        assignedOldest: search(query: $assignedOldest, type: ISSUE, first: 1) { nodes { ...DiscoveryIdentity } }
        assignedNewest: search(query: $assignedNewest, type: ISSUE, first: 1) { nodes { ...DiscoveryIdentity } }
        directOldest: search(query: $directOldest, type: ISSUE, first: 1) { nodes { ...DiscoveryIdentity } }
        directNewest: search(query: $directNewest, type: ISSUE, first: 1) { nodes { ...DiscoveryIdentity } }
        teamOldest: search(query: $teamOldest, type: ISSUE, first: 1) { nodes { ...DiscoveryIdentity } }
        teamNewest: search(query: $teamNewest, type: ISSUE, first: 1) { nodes { ...DiscoveryIdentity } }
      }
      fragment DiscoveryIdentity on PullRequest {
        id number createdAt repository { nameWithOwner }
      }
    """

    static let discoveryPage = """
      query DiscoverPullRequests(
        $authoredQuery: String!, $authoredCursor: String,
        $assignedQuery: String!, $assignedCursor: String,
        $directQuery: String!, $directCursor: String,
        $teamQuery: String!, $teamCursor: String
      ) {
        authored: search(query: $authoredQuery, type: ISSUE, first: 100, after: $authoredCursor) {
          issueCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
          nodes { ...DiscoveryIdentity }
        }
        assigned: search(query: $assignedQuery, type: ISSUE, first: 100, after: $assignedCursor) {
          issueCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
          nodes { ...DiscoveryIdentity }
        }
        direct: search(query: $directQuery, type: ISSUE, first: 100, after: $directCursor) {
          issueCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
          nodes { ...DiscoveryIdentity }
        }
        team: search(query: $teamQuery, type: ISSUE, first: 100, after: $teamCursor) {
          issueCount pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
          nodes { ...DiscoveryIdentity }
        }
      }
      fragment DiscoveryIdentity on PullRequest {
        id number createdAt repository { nameWithOwner }
      }
    """

    static let searchPage = """
      query SearchPullRequests($query: String!, $cursor: String) {
        search(query: $query, type: ISSUE, first: 100, after: $cursor) {
          issueCount
          pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
          nodes { ... on PullRequest { id number createdAt repository { nameWithOwner } } }
        }
      }
    """
}
