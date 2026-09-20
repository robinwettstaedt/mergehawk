import Foundation

enum GitHubPullRequestQueries {
    static let initialCommentPageSize = 10
    static let initialReviewPageSize = 10
    static let initialRelationshipPageSize = 20
    static let discoveryPageSize = 100
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
      author { id login avatarUrl(size: 64) }
      repository { nameWithOwner }
      comments(last: 10) {
        totalCount
        pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
        nodes { id createdAt viewerDidAuthor author { id login } }
      }
      reviews(last: 10) {
        totalCount
        pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
        nodes { id state submittedAt viewerDidAuthor author { id login } }
      }
      latestOpinionatedReviews(last: 20) {
        totalCount
        pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
        nodes { id state submittedAt viewerDidAuthor author { id login } }
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
              id createdAt viewerDidAuthor author { id login }
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
}
