import Foundation

enum GitHubPullRequestQueries {
    static let continuationPageSize = 100
    static let hydrationBatchSize = 20
    static let continuationBatchSize = 20

    static let pageInfoFields = "pageInfo { startCursor endCursor hasPreviousPage hasNextPage }"

    /// Node selections shared by hydration and every continuation of the same connection.
    static let conversationCommentFields =
        "id url createdAt publishedAt updatedAt bodyHTML viewerDidAuthor author { login __typename }"
    static let inlineCommentFields =
        "id url createdAt publishedAt updatedAt bodyHTML state viewerDidAuthor author { login __typename } pullRequestReview { id }"
    static let fullReviewFields =
        "id url state submittedAt updatedAt bodyHTML bodyText viewerDidAuthor author { login __typename }"
    /// Latest opinionated reviews only decide changes requested and unknown review data, so they carry no summary content.
    static let opinionatedReviewFields = "id url state submittedAt viewerDidAuthor author { login __typename }"

    static let conversationCommentConnectionFields = "totalCount \(pageInfoFields) nodes { \(conversationCommentFields) }"
    static let inlineCommentConnectionFields = "totalCount \(pageInfoFields) nodes { \(inlineCommentFields) }"
    static let fullReviewConnectionFields = "totalCount \(pageInfoFields) nodes { \(fullReviewFields) }"
    static let opinionatedReviewConnectionFields = "totalCount \(pageInfoFields) nodes { \(opinionatedReviewFields) }"
    static let reviewThreadNodeFields = "id isResolved viewerCanResolve comments(last: 10) { \(inlineCommentConnectionFields) }"

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
      reviewDecision
      additions
      deletions
      statusCheckRollup { state }
      author { login avatarUrl(size: 64) }
      repository { nameWithOwner isArchived }
      comments(last: 10) { \(conversationCommentConnectionFields) }
      reviews(last: 10) { \(fullReviewConnectionFields) }
      latestOpinionatedReviews(last: 20) { \(opinionatedReviewConnectionFields) }
      reviewThreads(last: 20) { totalCount \(pageInfoFields) nodes { \(reviewThreadNodeFields) } }
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

    /// Page sizes for the viewer-teams queries. GitHub multiplies nested `first` values when it checks a query
    /// against its 500,000 node limit, so these stay small enough for the nested selection to pass.
    static let viewerOrganizationPageSize = 20
    static let viewerTeamsPerOrganizationPageSize = 50
    static let organizationViewerTeamsPageSize = 100
    static let teamAncestorsPageSize = 20

    /// The viewer's direct teams in one org page, with each team's full ancestor chain.
    static let viewerTeamConnectionFields = """
      pageInfo { hasNextPage endCursor }
      nodes { id slug ancestors(first: \(teamAncestorsPageSize)) { pageInfo { hasNextPage } nodes { id slug } } }
    """

    static let viewerTeams = """
      query ViewerTeams($login: String!, $orgCursor: String) {
        viewer {
          organizations(first: \(viewerOrganizationPageSize), after: $orgCursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              login
              teams(first: \(viewerTeamsPerOrganizationPageSize), userLogins: [$login]) { \(viewerTeamConnectionFields) }
            }
          }
        }
      }
    """

    /// Only used for an org whose first page of the viewer's teams in `viewerTeams` has more pages.
    static let organizationViewerTeams = """
      query OrganizationViewerTeams($org: String!, $login: String!, $cursor: String) {
        organization(login: $org) {
          teams(first: \(organizationViewerTeamsPageSize), after: $cursor, userLogins: [$login]) {
            \(viewerTeamConnectionFields)
          }
        }
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
