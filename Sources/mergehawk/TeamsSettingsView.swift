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

    static let signedOutHeadline = "Sign in to see your teams"
    static let signedOutDetail = "Then choose which teams' review requests show up."
    static let noTeamsHeadline = "No teams found"
    static let noTeamsDetail = "MergeHawk checks your GitHub teams every 30 minutes. Use the refresh button to check now."
    static let caption = "Turn off a team to hide PRs and notifications that reach you only through that team. "
        + "Useful for broad teams that CODEOWNERS adds to every PR."
    static let refreshTeamsTitle = "Refresh teams"
    static let notificationsLinkTitle = "Set notifications for teams you haven't turned off here ›"
    static let notificationsLinkDestination = SettingsTab.notifications

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

    static func countHelp(for row: DashboardController.ReviewTeamRow) -> String {
        "PRs requesting \(row.team.displayName), including ones shown for another reason"
    }
}

private enum ReviewTeamsSettingsLayout {
    static let indentPerLevel: CGFloat = 20
    /// Lines the caption up with the grouped Form's section headers and row content below it.
    static let captionHorizontalInset: CGFloat = 30
    static let captionTopPadding: CGFloat = 20
}

struct TeamsSettingsView: View {
    @ObservedObject var controller: DashboardController
    @Binding var selection: SettingsTab

    @Environment(\.menuMetrics) private var metrics

    var body: some View {
        switch ReviewTeamsSettingsPresentation.content(
            authStatus: controller.state.authStatus,
            rows: controller.reviewTeamRows
        ) {
        case .signedOut:
            EmptyMenuState(
                text: ReviewTeamsSettingsPresentation.signedOutHeadline,
                systemImage: "person.3",
                detail: ReviewTeamsSettingsPresentation.signedOutDetail,
                action: .init(title: OpenAuthSettingsLink.title) {
                    selection = OpenAuthSettingsLink.destination
                }
            )
        case .noTeams:
            VStack(spacing: 0) {
                EmptyMenuState(
                    text: ReviewTeamsSettingsPresentation.noTeamsHeadline,
                    systemImage: "person.3",
                    detail: ReviewTeamsSettingsPresentation.noTeamsDetail
                )
                .fixedSize(horizontal: false, vertical: true)
                // The same gap EmptyMenuState leaves above its own action button.
                refreshTeamsControl
                    .padding(.top, 2 * metrics.emptyState.spacing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .teams(let groups):
            VStack(spacing: 0) {
                // A plain row above the Form, like the Sources search and refresh row: a grouped Form's section
                // header restyles its content, which drew the refresh control smaller than in Sources.
                captionRow
                    .padding(.horizontal, ReviewTeamsSettingsLayout.captionHorizontalInset)
                    .padding(.top, ReviewTeamsSettingsLayout.captionTopPadding)
                Form {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.rows) { row in
                                ReviewTeamSettingsRow(row: row, controller: controller)
                            }
                        } header: {
                            organizationHeader(group)
                        }
                    }
                }
                .formStyle(.grouped)
                // Below the Form, so no row scrolls behind it and it sits on the window background like the
                // install link at the bottom of Sources.
                notificationsLink
            }
        }
    }

    /// The Sources pane's refresh control, showing when the teams were last read.
    private var refreshTeamsControl: some View {
        RefreshStatusControl(
            indicatorColor: .secondary,
            isRefreshing: controller.isRefreshing,
            updatedAt: controller.state.viewerTeamsReadAt,
            action: controller.refreshTeams,
            isRefreshEnabled: !controller.isRefreshing,
            help: ReviewTeamsSettingsPresentation.refreshTeamsTitle,
            accessibilityLabel: ReviewTeamsSettingsPresentation.refreshTeamsTitle,
            keyboardShortcut: KeyboardShortcut("r", modifiers: .command),
            timestampPrefix: "",
            width: 58,
            displayMode: .horizontalButton(height: 24),
            showsIndicator: false
        )
    }

    private var captionRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(ReviewTeamsSettingsPresentation.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            refreshTeamsControl
        }
    }

    private var notificationsLink: some View {
        Button {
            selection = ReviewTeamsSettingsPresentation.notificationsLinkDestination
        } label: {
            Text(ReviewTeamsSettingsPresentation.notificationsLinkTitle)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        // No bottom padding, so the link sits as low as the install link at the bottom of Sources.
        .padding(.top, 14)
    }

    private func organizationHeader(_ group: ReviewTeamsSettingsPresentation.OrganizationGroup) -> some View {
        HStack(spacing: 6) {
            TeamSettingsAvatar(url: group.avatarURL, placeholderSystemImage: "building.2")
            Text(group.organization)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(group.organization)
    }
}

private struct ReviewTeamSettingsRow: View {
    let row: DashboardController.ReviewTeamRow
    @ObservedObject var controller: DashboardController

    var body: some View {
        // The row is the switch's label: in a grouped Form, a switch beside its row content with a hidden label
        // exposes no press action to assistive tools, so VoiceOver could not toggle it.
        Toggle(isOn: Binding {
            row.isCounting
        } set: { counting in
            controller.setReviewTeam(row.team.id, counting: counting)
        }) {
            rowContent
        }
        .toggleStyle(.switch)
        .accessibilityLabel("Show review requests from \(row.team.displayName)")
    }

    private var rowContent: some View {
        let indent = ReviewTeamsSettingsLayout.indentPerLevel
        return HStack(spacing: 0) {
            if row.depth > 0 {
                // The marker sits at the parent's inset, so every child of one parent lines up below it.
                Text("└")
                    .fontWeight(.light)
                    .foregroundStyle(.tertiary)
                    .frame(width: indent, alignment: .leading)
                    .padding(.leading, CGFloat(row.depth - 1) * indent)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                TeamSettingsAvatar(url: row.avatarURL, placeholderSystemImage: "person.3")
                    .opacity(row.isCounting ? 1 : 0.4)
                Text(row.team.slug)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(row.isCounting ? .primary : .tertiary)
                    .help(row.team.displayName)
                Text("· \(ReviewTeamsSettingsPresentation.countLabel(for: row))")
                    .foregroundStyle(row.isCounting ? .secondary : .tertiary)
                    .fixedSize()
                    .help(ReviewTeamsSettingsPresentation.countHelp(for: row))
            }
        }
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
