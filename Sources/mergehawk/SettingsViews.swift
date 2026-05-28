import AppKit
import SwiftUI
import mergehawkcore

enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case github
    case notifications
    case sources
    case about

    static let defaultWindowSize = CGSize(width: 500, height: 580)

    var title: String {
        switch self {
        case .general: "General"
        case .github: "GitHub"
        case .notifications: "Notifications"
        case .sources: "Sources"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .github: "person.crop.circle.badge.checkmark"
        case .notifications: "bell"
        case .sources: "tray.full"
        case .about: "info.circle"
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var controller: DashboardController
    @State private var selection = SettingsTab.general
    private let initialSourcesSearchState: ExpandableSearchState

    init(
        controller: DashboardController,
        selection: SettingsTab = .general,
        initialSourcesSearchState: ExpandableSearchState = ExpandableSearchState()
    ) {
        self.controller = controller
        self._selection = State(initialValue: selection)
        self.initialSourcesSearchState = initialSourcesSearchState
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selection)
                .padding(.top, SettingsTabLayout.topPadding)
                .padding(.bottom, SettingsTabLayout.bottomPadding)

            Divider()

            selectedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            width: SettingsTab.defaultWindowSize.width,
            height: SettingsTab.defaultWindowSize.height
        )
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch selection {
        case .general:
            GeneralSettingsView(controller: controller)
        case .github:
            GitHubSettingsView(controller: controller)
        case .notifications:
            NotificationSettingsView(controller: controller)
        case .sources:
            SourcesSettingsView(
                controller: controller,
                initialSearchState: initialSourcesSearchState
            )
        case .about:
            AboutSettingsView()
        }
    }
}

enum SettingsTabLayout {
    static let topPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 10
    static let titleToTabsSpacing: CGFloat = 8
    static let tabSpacing: CGFloat = 8
    static let tabWidth: CGFloat = 76
    static let tabHeight: CGFloat = 58
    static let titleSize: CGFloat = 14
    static let iconSize: CGFloat = 18
    static let iconHeight: CGFloat = 20
    static let labelSize: CGFloat = 11
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        VStack(spacing: SettingsTabLayout.titleToTabsSpacing) {
            Text(selection.title)
                .font(.system(size: SettingsTabLayout.titleSize, weight: .semibold))
                .foregroundStyle(.primary)

            HStack(spacing: SettingsTabLayout.tabSpacing) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        selection = tab
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: SettingsTabLayout.iconSize, weight: .semibold))
                                .frame(height: SettingsTabLayout.iconHeight)
                            Text(tab.title)
                                .font(.system(size: SettingsTabLayout.labelSize, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                        .frame(width: SettingsTabLayout.tabWidth, height: SettingsTabLayout.tabHeight)
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                                    }
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        Form {
            Toggle("Start at login", isOn: Binding(
                get: { controller.startsAtLogin },
                set: { controller.setStartsAtLogin($0) }
            ))
            LabeledContent("Source", value: controller.sourceLabel)
            LabeledContent("Account", value: controller.accountLabel)
            Picker("Refresh Interval", selection: $controller.refreshIntervalMinutes) {
                ForEach(controller.refreshIntervalOptions, id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
    }
}

struct AboutPanelContent {
    struct LinkItem: Equatable {
        let title: String
        let systemImage: String
        let url: URL
    }

    static let appName = "MergeHawk"
    static let credits = "Eyes on the pull requests that matter to you."
    static let footer = "© 2026 Robin Wettstädt. MIT license."
    static let links = [
        LinkItem(
            title: "GitHub",
            systemImage: "chevron.left.forwardslash.chevron.right",
            url: URL(string: "https://github.com/robinwettstaedt/mergehawk")!
        ),
        LinkItem(
            title: "Website",
            systemImage: "globe",
            url: URL(string: "https://mergehawk.dev")!
        ),
    ]

    static func versionText(bundle: Bundle = .main) -> String {
        let isAppBundle = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL"
        let version = isAppBundle
            ? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
            : "0.1.0"
        let build = isAppBundle
            ? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
            : "1"
        return "Version \(version) (\(build))"
    }

    static func logoImage() -> NSImage? {
        for url in logoURLs {
            guard let image = NSImage(contentsOf: url) else {
                continue
            }
            image.size = NSSize(width: 128, height: 128)
            return image
        }
        return nil
    }

    private static var logoURLs: [URL] {
        [
            Bundle.main.url(forResource: "MergeHawkAppIcon", withExtension: "png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Design/mergehawk_logo_without_text.png"),
        ].compactMap(\.self)
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 28) {
                if let logo = AboutPanelContent.logoImage() {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 128, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityHidden(true)
                }

                VStack(spacing: 10) {
                    Text(AboutPanelContent.appName)
                        .font(.system(size: 26, weight: .bold))
                    Text(AboutPanelContent.versionText())
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(AboutPanelContent.credits)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 14) {
                    ForEach(AboutPanelContent.links, id: \.title) { item in
                        Link(destination: item.url) {
                            Label(item.title, systemImage: item.systemImage)
                                .font(.system(size: 15, weight: .semibold))
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 48)

            Spacer(minLength: 0)

            Text(AboutPanelContent.footer)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GitHubSettingsView: View {
    @ObservedObject var controller: DashboardController
    @State private var token = ""
    @State private var showsTokenFallback = false
    @FocusState private var tokenFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if controller.state.authStatus == .signedIn {
                        VStack(spacing: 14) {
                            VStack(spacing: 6) {
                                Text("Signed in")
                                    .font(.headline)
                                Text(controller.accountLabel)
                                    .foregroundStyle(.secondary)
                                Text(controller.authMethod.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Sign Out", role: .destructive) {
                                controller.signOut()
                            }
                            if controller.authMethod == .oauth {
                                GitHubAppAccessNotes(showsInstallLink: false)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("MergeHawk GitHub App")
                                .font(.headline)
                            (
                                Text("Sign in through GitHub.com with the MergeHawk GitHub App. Access is limited by your GitHub permissions and the repositories where the app is installed. MergeHawk only performs ")
                                + Text("read")
                                    .bold()
                                    .underline()
                                + Text(" API calls.")
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack {
                                Button {
                                    connectWithGitHub()
                                } label: {
                                    Text("Sign in with GitHub")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .frame(height: 28)
                                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(controller.isRefreshing)
                                Spacer()
                            }

                            GitHubAppAccessNotes(showsInstallLink: true)
                        }

                        DisclosureGroup(isExpanded: $showsTokenFallback) {
                            VStack(alignment: .leading, spacing: 8) {
                                SecureField("github_pat_... or ghp_...", text: $token)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($tokenFieldFocused)
                                    .onSubmit {
                                        connectWithToken()
                                    }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Advanced fallback for restricted workplaces or debugging.")
                                    Text("Use a classic token for GitHub Inbox notifications in Notifications > Other.")
                                    (
                                        Text("MergeHawk only ever needs ")
                                        + Text("read access")
                                            .bold()
                                            .underline()
                                        + Text(" to your GitHub data.")
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Classic PAT:")
                                        Text("• Select repo")
                                        Text("• Select read:user")
                                        Text("• Select read:org")
                                        Text("• Required for Notifications > Other")
                                    }
                                    .padding(.top, 4)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Fine-grained PAT for PR data:")
                                        Text("• Repository access for the repos MergeHawk monitors")
                                        Text("• Metadata: Read-only")
                                        Text("• Pull requests: Read-only")
                                        Text("• Issues: Read-only")
                                        Text("• Commit statuses: Read-only")
                                        Text("• Checks: Read-only")
                                        Text("• Does not support Notifications > Other")
                                    }
                                    .padding(.top, 4)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                Button("Connect with token") {
                                    connectWithToken()
                                }
                                .buttonStyle(.bordered)
                                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            .padding(.top, 8)
                        } label: {
                            Button {
                                showsTokenFallback.toggle()
                            } label: {
                                Text("Use personal access token instead")
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use personal access token instead")
                        }
                        .padding(.top, 6)
                    }

                    if let error = controller.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                .padding(.top, 20)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            GitHubOAuthAccessButton(controller: controller)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if controller.state.authStatus != .signedIn, showsTokenFallback {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    tokenFieldFocused = true
                }
            }
        }
    }

    private func connectWithGitHub() {
        Task {
            await controller.signInWithGitHub()
        }
    }

    private func connectWithToken() {
        Task {
            await controller.signInWithToken(token)
            if controller.state.authStatus == .signedIn {
                token = ""
            }
        }
    }
}

private struct NotificationSettingsView: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        Form {
            Toggle("macOS local notifications", isOn: $controller.macOSLocalNotificationsEnabled)
            Section("Pull request notifications") {
                Grid(horizontalSpacing: NotificationMatrixLayout.columnSpacing, verticalSpacing: 8) {
                    GridRow {
                        Text("Notify me for")
                            .frame(width: NotificationMatrixLayout.relationshipColumnWidth, alignment: .leading)
                        ForEach(PullRequestNotificationActivity.allCases, id: \.self) { activity in
                            Text(activity.columnTitle)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: NotificationMatrixLayout.activityColumnWidth(for: activity))
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    Divider()
                        .gridCellColumns(PullRequestNotificationActivity.allCases.count + 1)

                    ForEach(PullRequestNotificationRelationship.allCases, id: \.self) { relationship in
                        GridRow {
                            Text(relationship.title)
                                .frame(width: NotificationMatrixLayout.relationshipColumnWidth, alignment: .leading)
                            ForEach(PullRequestNotificationActivity.allCases, id: \.self) { activity in
                                if showsMatrixToggle(relationship: relationship, activity: activity) {
                                    Toggle("", isOn: matrixBinding(relationship: relationship, activity: activity))
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                        .frame(width: NotificationMatrixLayout.activityColumnWidth(for: activity))
                                        .accessibilityLabel("\(relationship.title) \(activity.accessibilityTitle)")
                                } else {
                                    Color.clear
                                        .frame(width: NotificationMatrixLayout.activityColumnWidth(for: activity))
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    private func matrixBinding(
        relationship: PullRequestNotificationRelationship,
        activity: PullRequestNotificationActivity
    ) -> Binding<Bool> {
        Binding(
            get: {
                controller.preferences.preferences(for: relationship).allows(activity)
            },
            set: { isEnabled in
                var preferences = controller.preferences
                var activityPreferences = preferences.preferences(for: relationship)
                switch activity {
                case .comments:
                    activityPreferences.comments = isEnabled
                case .reviewActivity:
                    activityPreferences.reviewActivity = isEnabled
                case .ciFailures:
                    activityPreferences.ciFailures = isEnabled
                case .relationshipChanges:
                    activityPreferences.relationshipChanges = isEnabled
                case .otherCommits:
                    activityPreferences.otherCommits = isEnabled
                }
                preferences.set(activityPreferences, for: relationship)
                controller.preferences = preferences
            }
        )
    }

    private func showsMatrixToggle(
        relationship: PullRequestNotificationRelationship,
        activity: PullRequestNotificationActivity
    ) -> Bool {
        switch activity {
        case .relationshipChanges:
            relationship != .authored
        case .otherCommits:
            relationship == .authored
        case .comments, .reviewActivity, .ciFailures:
            true
        }
    }
}

private enum NotificationMatrixLayout {
    static let relationshipColumnWidth: CGFloat = 150
    static let columnSpacing: CGFloat = 0

    static func activityColumnWidth(for activity: PullRequestNotificationActivity) -> CGFloat {
        switch activity {
        case .relationshipChanges, .otherCommits:
            72
        case .comments, .reviewActivity, .ciFailures:
            52
        }
    }
}

private extension PullRequestNotificationRelationship {
    var title: String {
        switch self {
        case .authored:
            "Authored PRs"
        case .assigned:
            "Assigned PRs"
        case .directReviewRequest:
            "Direct review requests"
        case .teamReviewRequest:
            "Team review requests"
        }
    }
}

private extension PullRequestNotificationActivity {
    var columnTitle: String {
        switch self {
        case .comments:
            "Comments"
        case .reviewActivity:
            "Reviews"
        case .ciFailures:
            "CI failed"
        case .relationshipChanges:
            "Assigned/\nRequested"
        case .otherCommits:
            "Other\ncommits"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .comments:
            "comments"
        case .reviewActivity:
            "review activity"
        case .ciFailures:
            "CI failures"
        case .relationshipChanges:
            "assigned or requested"
        case .otherCommits:
            "commits by others on authored PRs"
        }
    }
}

private struct SourcesSettingsView: View {
    @ObservedObject var controller: DashboardController
    @State private var sourceSearchState = ExpandableSearchState()

    init(
        controller: DashboardController,
        initialSearchState: ExpandableSearchState = ExpandableSearchState()
    ) {
        self.controller = controller
        _sourceSearchState = State(initialValue: initialSearchState)
    }

    var body: some View {
        let filteredCatalog = SourceCatalogSearch.filteredCatalog(
            controller.sourceCatalog,
            query: sourceSearchState.query
        )

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    sourceCount(for: filteredCatalog)
                    CountSearchControl(
                        searchState: $sourceSearchState,
                        countLabel: sourceCountLabel(for: filteredCatalog),
                        placeholder: "Search sources",
                        help: "Search sources",
                        isAlwaysExpanded: true,
                        showsInlineCount: false
                    )

                    Spacer(minLength: 0)
                    RefreshStatusControl(
                        indicatorColor: .secondary,
                        isRefreshing: controller.isRefreshingSources,
                        updatedAt: controller.sourceCatalogSyncedAt,
                        action: controller.refreshSources,
                        isRefreshEnabled: controller.state.authStatus == .signedIn,
                        help: "Refresh sources",
                        accessibilityLabel: "Refresh sources",
                        keyboardShortcut: KeyboardShortcut("r", modifiers: .command),
                        timestampPrefix: "",
                        width: 58,
                        displayMode: .horizontalButton(height: 24),
                        showsIndicator: false
                    )
                }
                .padding(.bottom, 6)

                SourceHeaderRow()

                if controller.showsGitHubAppRepositoryAccessPrompt {
                    GitHubAppRepositoryAccessPrompt(controller: controller, minHeight: 360)
                } else if controller.sourceCatalog.repositoryCount == 0 {
                    Text(controller.state.authStatus == .signedIn ? "No sources found." : "Sign in to GitHub to manage sources.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if filteredCatalog.repositoryCount == 0 {
                    Text("No sources match \"\(sourceSearchState.trimmedQuery)\".")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredCatalog.owners) { owner in
                                OwnerSourceSettingsSection(
                                    owner: owner,
                                    controller: controller
                                )
                                Divider()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .simultaneousGesture(TapGesture().onEnded {
                        sourceSearchState.blur()
                    })
                }

                if let error = controller.sourceErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if !controller.showsGitHubAppRepositoryAccessPrompt {
                GitHubAppInstallationButton(controller: controller)
                    .padding(.horizontal, 20)
                    .padding(.top, 48)
                    .padding(.bottom, 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            controller.refreshSources()
        }
    }

    private func sourceCountLabel(for catalog: SourceCatalog) -> String {
        CountSearchPresentation.countLabel(
            for: SourceCatalogSearch.sourceCount(catalog),
            singular: "source",
            plural: "sources"
        )
    }

    private func sourceCount(for catalog: SourceCatalog) -> some View {
        Text("\(SourceCatalogSearch.sourceCount(catalog))")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .accessibilityLabel(sourceCountLabel(for: catalog))
    }
}

private struct GitHubAppAccessNotes: View {
    var showsInstallLink: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Private organization repositories require the MergeHawk GitHub App to be installed on that organization or selected repositories.")
            Text("GitHub Inbox notifications in Notifications > Other require the classic personal access token fallback.")
            if showsInstallLink {
                Link("Install MergeHawk GitHub App", destination: MergeHawkAuthDefaults.installURL)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GitHubOAuthAccessButton: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        Button {
            controller.open(MergeHawkAuthDefaults.authorizedAppSettingsURL)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                Text("Manage GitHub App Authorization")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(controller.state.authStatus != .signedIn)
        .help("Manage MergeHawk GitHub App authorization")
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct GitHubAppInstallationButton: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        Button {
            controller.openGitHubAppInstallation()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                Text(GitHubAppRepositoryAccessCopy.buttonTitle)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(controller.state.authStatus != .signedIn || controller.authMethod != .oauth)
        .help("Install or manage MergeHawk GitHub App repository access")
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

enum SourceCatalogSearch {
    static func filteredCatalog(_ catalog: SourceCatalog, query: String) -> SourceCatalog {
        let searchText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else {
            return catalog
        }

        return SourceCatalog(owners: catalog.owners.compactMap { owner in
            if owner.owner.range(of: searchText, options: [.caseInsensitive]) != nil {
                return owner
            }

            let matchingRepositories = owner.repositories.filter { repository in
                repository.identity.name.range(of: searchText, options: [.caseInsensitive]) != nil
                    || repository.identity.nameWithOwner.range(of: searchText, options: [.caseInsensitive]) != nil
            }
            guard !matchingRepositories.isEmpty else {
                return nil
            }
            return OwnerSource(owner: owner.owner, repositories: matchingRepositories)
        })
    }

    static func sourceCount(_ catalog: SourceCatalog) -> Int {
        catalog.repositoryCount
    }
}

private struct SourceHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Owner / Repository")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Notifications")
                .frame(width: SourceSettingsLayout.columnWidth)
            Text(SourceSettingsCopy.authoredTitle)
                .frame(width: SourceSettingsLayout.columnWidth)
            Text(SourceSettingsCopy.requestedTitle)
                .frame(width: SourceSettingsLayout.columnWidth)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.trailing, 4)
    }
}

private enum SourceSettingsLayout {
    static let columnWidth: CGFloat = 84
    static let rowHeight: CGFloat = 34
    static let disclosureHitSlop: CGFloat = 8
}

enum SourceSettingsCopy {
    static let authoredTitle = "Authored"
    static let requestedTitle = "Requested"
}

private struct OwnerSourceSettingsSection: View {
    let owner: OwnerSource
    @ObservedObject var controller: DashboardController
    @State private var isExpanded = false

    var body: some View {
        if owner.repositories.isEmpty {
            OwnerSourceSettingsRow(owner: owner.owner, controller: controller)
                .padding(.vertical, 4)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(owner.repositories) { repository in
                        RepositorySourceSettingsRow(
                            repository: repository,
                            controller: controller
                        )
                    }
                }
            } label: {
                OwnerSourceSettingsRow(
                    owner: owner.owner,
                    controller: controller,
                    onOwnerTap: {
                        isExpanded.toggle()
                    }
                )
            }
            .padding(.vertical, 4)
        }
    }
}

private struct OwnerSourceSettingsRow: View {
    let owner: String
    @ObservedObject var controller: DashboardController
    var onOwnerTap: (() -> Void)?

    var body: some View {
        let preferences = controller.sourcePreferences.ownerPreferences(for: owner)
        let notificationStatus = preferences.notifications ? "on" : "off"
        let authoredStatus = preferences.myPullRequests ? "on" : "off"
        let requestedStatus = preferences.reviewRequests ? "on" : "off"

        HStack(spacing: 8) {
            ownerLabel
            Toggle("", isOn: ownerBinding(\.notifications))
                .labelsHidden()
                .frame(width: SourceSettingsLayout.columnWidth)
            Toggle("", isOn: ownerBinding(\.myPullRequests))
                .labelsHidden()
                .frame(width: SourceSettingsLayout.columnWidth)
            Toggle("", isOn: ownerBinding(\.reviewRequests))
                .labelsHidden()
                .frame(width: SourceSettingsLayout.columnWidth)
        }
        .frame(height: SourceSettingsLayout.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(owner), notifications \(notificationStatus), "
                + "\(SourceSettingsCopy.authoredTitle.lowercased()) \(authoredStatus), "
                + "\(SourceSettingsCopy.requestedTitle.lowercased()) \(requestedStatus)"
        )
    }

    @ViewBuilder
    private var ownerLabel: some View {
        if let onOwnerTap {
            Button {
                onOwnerTap()
            } label: {
                ownerText
                    .padding(.vertical, SourceSettingsLayout.disclosureHitSlop)
                    .contentShape(Rectangle())
                    .padding(.vertical, -SourceSettingsLayout.disclosureHitSlop)
            }
            .buttonStyle(.plain)
        } else {
            ownerText
        }
    }

    private var ownerText: some View {
        Text(owner)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ownerBinding(_ keyPath: WritableKeyPath<OwnerSourcePreferences, Bool>) -> Binding<Bool> {
        Binding {
            controller.sourcePreferences.ownerPreferences(for: owner)[keyPath: keyPath]
        } set: { value in
            var preferences = controller.sourcePreferences.ownerPreferences(for: owner)
            preferences[keyPath: keyPath] = value
            controller.setOwnerPreferences(owner: owner, preferences: preferences)
        }
    }
}

private struct RepositorySourceSettingsRow: View {
    let repository: RepositorySource
    @ObservedObject var controller: DashboardController

    var body: some View {
        HStack(spacing: 8) {
            Text(repository.identity.name)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            overridePicker(binding: repositoryBinding(\.notifications))
            overridePicker(binding: repositoryBinding(\.myPullRequests))
            overridePicker(binding: repositoryBinding(\.reviewRequests))
        }
        .frame(height: SourceSettingsLayout.rowHeight)
    }

    private func overridePicker(binding: Binding<SourceOverride>) -> some View {
        Picker("", selection: binding) {
            ForEach(SourceOverride.allCases, id: \.self) { option in
                Text(option.settingsLabel).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: SourceSettingsLayout.columnWidth)
    }

    private func repositoryBinding(
        _ keyPath: WritableKeyPath<RepositorySourcePreferences, SourceOverride>
    ) -> Binding<SourceOverride> {
        Binding {
            controller.sourcePreferences.repositoryPreferences(for: repository.identity.nameWithOwner)[keyPath: keyPath]
        } set: { value in
            var preferences = controller.sourcePreferences.repositoryPreferences(for: repository.identity.nameWithOwner)
            preferences[keyPath: keyPath] = value
            controller.setRepositoryPreferences(
                repo: repository.identity.nameWithOwner,
                preferences: preferences
            )
        }
    }
}

private extension SourceOverride {
    var settingsLabel: String {
        switch self {
        case .inherit:
            "Inherit"
        case .enabled:
            "On"
        case .disabled:
            "Off"
        }
    }
}
