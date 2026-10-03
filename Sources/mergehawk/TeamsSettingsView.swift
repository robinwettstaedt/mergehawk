import SwiftUI
import mergehawkcore

enum ReviewTeamsSettingsPresentation {
    struct OrganizationGroup: Identifiable, Equatable {
        let organization: String
        let rows: [DashboardController.ReviewTeamRow]

        var id: String { organization }
        var avatarURL: URL? { rows.lazy.compactMap(\.organizationAvatarURL).first }
    }

    enum Content: Equatable {
        case signedOut
        case noTeams
        case teams([OrganizationGroup])
    }

    static let signedOutText = "Sign in to GitHub to manage teams."
    static let noTeamsText = "You're not in any GitHub teams."
    static let listLabel = "Show review requests from these teams:"

    /// Shows the last complete PR refresh's teams, grouped by organization in the controller's tree order.
    static func content(authStatus: AuthStatus, rows: [DashboardController.ReviewTeamRow]) -> Content {
        guard authStatus == .signedIn else { return .signedOut }
        guard !rows.isEmpty else { return .noTeams }
        var groups: [OrganizationGroup] = []
        for row in rows {
            if let last = groups.last, last.organization == row.team.organization {
                groups[groups.count - 1] = OrganizationGroup(organization: last.organization, rows: last.rows + [row])
            } else {
                groups.append(OrganizationGroup(organization: row.team.organization, rows: [row]))
            }
        }
        return .teams(groups)
    }

    static func countLabel(for row: DashboardController.ReviewTeamRow) -> String {
        "\(row.pullRequestCount) \(row.pullRequestCount == 1 ? "PR" : "PRs")"
    }
}

private enum ReviewTeamsSettingsLayout {
    static let organizationRowHeight: CGFloat = 30
    static let teamRowHeight: CGFloat = 26
    static let indentPerLevel: CGFloat = 20
}

struct TeamsSettingsView: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        switch ReviewTeamsSettingsPresentation.content(
            authStatus: controller.state.authStatus,
            rows: controller.reviewTeamRows
        ) {
        case .signedOut:
            Text(ReviewTeamsSettingsPresentation.signedOutText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .noTeams:
            EmptyMenuState(text: ReviewTeamsSettingsPresentation.noTeamsText, systemImage: "person.3")
        case .teams(let groups):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(ReviewTeamsSettingsPresentation.listLabel)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    ForEach(groups) { group in
                        if group.id != groups.first?.id {
                            Divider()
                                .padding(.vertical, 6)
                        }
                        HStack(spacing: 6) {
                            TeamSettingsAvatar(url: group.avatarURL, placeholderSystemImage: "building.2")
                            Text(group.organization)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                        }
                        .frame(height: ReviewTeamsSettingsLayout.organizationRowHeight)
                        ForEach(group.rows) { row in
                            ReviewTeamSettingsRow(row: row, controller: controller)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ReviewTeamSettingsRow: View {
    let row: DashboardController.ReviewTeamRow
    @ObservedObject var controller: DashboardController

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding {
                row.isCounting
            } set: { counting in
                controller.setReviewTeam(row.team.id, counting: counting)
            }) {
                HStack(spacing: 6) {
                    TeamSettingsAvatar(url: row.avatarURL, placeholderSystemImage: "person.3")
                    Text(row.team.slug)
                        .font(.callout)
                        .lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Show review requests from \(row.team.displayName)")
            CountBubble(text: ReviewTeamsSettingsPresentation.countLabel(for: row))
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * ReviewTeamsSettingsLayout.indentPerLevel)
        .frame(height: ReviewTeamsSettingsLayout.teamRowHeight)
    }
}

/// A team or organization avatar as a small rounded square, like GitHub shows them.
private struct TeamSettingsAvatar: View {
    let url: URL?
    let placeholderSystemImage: String

    static let size: CGFloat = 16

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: placeholderSystemImage)
            .resizable()
            .scaledToFit()
            .padding(2)
            .foregroundStyle(.secondary)
            .frame(width: Self.size, height: Self.size)
            .background(Color.secondary.opacity(0.15))
    }
}
