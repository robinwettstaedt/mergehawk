import Foundation

struct GitHubPageInfo: Decodable, Equatable, Sendable {
    let startCursor: String?
    let endCursor: String?
    let hasPreviousPage: Bool
    let hasNextPage: Bool
}

struct GitHubStrictConnection<Node: Decodable & Equatable & Sendable>: Decodable, Equatable, Sendable {
    let totalCount: Int?
    let nodes: [Node]
    let pageInfo: GitHubPageInfo
}

struct GitHubPayloadUser: Decodable, Equatable, Sendable {
    let id: String?
    let login: String
    let avatarUrl: URL?
}

struct GitHubPayloadComment: Decodable, Equatable, Sendable {
    let id: String
    let createdAt: String
    let viewerDidAuthor: Bool
    let author: GitHubPayloadUser?
    let pullRequestReview: ReviewIdentity?

    struct ReviewIdentity: Decodable, Equatable, Sendable {
        let id: String
    }
}

struct GitHubPayloadReview: Decodable, Equatable, Sendable {
    let id: String
    let state: String
    let submittedAt: String?
    let viewerDidAuthor: Bool
    let author: GitHubPayloadUser?
}

struct GitHubPayloadReviewThread: Decodable, Equatable, Sendable {
    let id: String
    let isResolved: Bool
    let viewerCanResolve: Bool
    let comments: GitHubStrictConnection<GitHubPayloadComment>
}

struct GitHubPayloadRequestedReviewer: Decodable, Equatable, Sendable {
    let typename: String
    let id: String?
    let login: String?
    let slug: String?
    let organization: Organization?

    struct Organization: Decodable, Equatable, Sendable {
        let login: String
    }

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case id
        case login
        case slug
        case organization
    }
}

struct GitHubPayloadReviewRequest: Decodable, Equatable, Sendable {
    let id: String
    let requestedReviewer: GitHubPayloadRequestedReviewer?
}

struct GitHubPayloadStatusRollup: Decodable, Equatable, Sendable {
    let state: String?
}

struct GitHubCompletePullRequestPayload: Decodable, Equatable, Sendable {
    let id: String
    let title: String
    let number: Int
    let url: String
    let state: String
    let createdAt: String
    let updatedAt: String
    let headRefName: String
    let headRefOid: String
    let isDraft: Bool
    let mergeable: String?
    let additions: Int?
    let deletions: Int?
    let statusCheckRollup: GitHubPayloadStatusRollup?
    let author: GitHubPayloadUser?
    let repository: Repository
    let comments: GitHubStrictConnection<GitHubPayloadComment>
    let reviews: GitHubStrictConnection<GitHubPayloadReview>
    let latestOpinionatedReviews: GitHubStrictConnection<GitHubPayloadReview>
    let reviewThreads: GitHubStrictConnection<GitHubPayloadReviewThread>
    let assignees: GitHubStrictConnection<GitHubPayloadUser>
    let reviewRequests: GitHubStrictConnection<GitHubPayloadReviewRequest>

    struct Repository: Decodable, Equatable, Sendable {
        let nameWithOwner: String
    }
}

struct GitHubGraphQLErrorPayload: Decodable, Equatable, Sendable {
    let message: String
    let type: String?
    let path: [GitHubGraphQLPathComponent]?
}

enum GitHubGraphQLPathComponent: Decodable, Equatable, Sendable {
    case field(String)
    case index(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let field = try? container.decode(String.self) {
            self = .field(field)
        } else {
            self = .index(try container.decode(Int.self))
        }
    }
}

struct GitHubGraphQLPayload<DataPayload: Decodable>: Decodable {
    let data: DataPayload?
    let errors: [GitHubGraphQLErrorPayload]?
}

enum GitHubReadError: Error, Equatable, Sendable {
    case authentication
    case accessDenied
    case rateLimited(retryAt: Date?)
    case http(status: Int)
    case validation(String)
    case graphQL([GitHubGraphQLErrorPayload])
    case invalidPayload
    case transport(URLError.Code)
    case incompleteCoverage(String)
}

enum GitHubQueryValue: Encodable, Equatable, Sendable {
    case string(String)
    case strings([String])
    case integer(Int)
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct GitHubDiscoveryNode: Decodable, Equatable, Sendable {
    let id: String
    let number: Int
    let createdAt: String
    let repository: Repository

    struct Repository: Decodable, Equatable, Sendable {
        let nameWithOwner: String
    }
}

struct GitHubDiscoverySearchPayload: Decodable, Equatable, Sendable {
    let issueCount: Int
    let nodes: [GitHubDiscoveryNode?]
    let pageInfo: GitHubPageInfo
}

struct GitHubReadRetryPolicy: Sendable {
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    typealias Now = @Sendable () -> Date

    let now: Now
    let sleep: Sleep

    init(
        now: @escaping Now = { Date() },
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.now = now
        self.sleep = sleep
    }

    func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let backoffs: [TimeInterval] = [1, 2]
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as GitHubReadError {
                guard attempt < backoffs.count, error.isOrdinaryTransient else { throw error }
                try await sleep(backoffs[attempt])
                attempt += 1
            } catch let error as URLError {
                guard attempt < backoffs.count else { throw GitHubReadError.transport(error.code) }
                try await sleep(backoffs[attempt])
                attempt += 1
            }
        }
    }
}

private extension GitHubReadError {
    var isOrdinaryTransient: Bool {
        switch self {
        case .http(let status):
            return (500...599).contains(status)
        case .transport:
            return true
        case .authentication, .accessDenied, .rateLimited, .validation, .graphQL, .invalidPayload,
             .incompleteCoverage:
            return false
        }
    }
}
