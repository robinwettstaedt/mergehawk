import SwiftUI
import mergehawkcore

enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case github
    case notifications
    case sources
    case about

    static let defaultWindowSize = CGSize(width: 560, height: 580)

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

    init(controller: DashboardController, selection: SettingsTab = .general) {
        self.controller = controller
        self._selection = State(initialValue: selection)
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
            SourcesSettingsView(controller: controller)
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
            Button("Refresh Now") {
                controller.refresh()
            }
        }
        .formStyle(.grouped)
    }
}

private struct GitHubSettingsView: View {
    @ObservedObject var controller: DashboardController
    @State private var token = ""
    @State private var showsTokenFallback = false
    @FocusState private var tokenFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.state.authStatus == .signedIn {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Signed in")
                        .font(.headline)
                    Text(controller.accountLabel)
                        .foregroundStyle(.secondary)
                    Text(controller.authMethod.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Sign Out", role: .destructive) {
                    controller.signOut()
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("GitHub OAuth")
                        .font(.headline)
                    Text("Sign in through GitHub.com. MergeHawk requests broad OAuth repository access so it can read private PRs, but the app only performs read API calls.")
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
                }

                DisclosureGroup("Use personal access token", isExpanded: $showsTokenFallback) {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("github_pat_...", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .focused($tokenFieldFocused)
                            .onSubmit {
                                connectWithToken()
                            }
                        Text("Advanced fallback for restricted workplaces or debugging. Fine-grained PATs need read access for metadata, pull requests, issues, and actions on the repositories MergeHawk monitors.")
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
                }
            }

            if let error = controller.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Spacer()
        }
        .padding(20)
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
            Toggle("New comments", isOn: Binding(
                get: { controller.preferences.newComment },
                set: { controller.preferences.newComment = $0 }
            ))
            Toggle("New reviews", isOn: Binding(
                get: { controller.preferences.newReview },
                set: { controller.preferences.newReview = $0 }
            ))
            Toggle("Failed CI", isOn: Binding(
                get: { controller.preferences.ciFailed },
                set: { controller.preferences.ciFailed = $0 }
            ))
            Toggle("Changes requested", isOn: Binding(
                get: { controller.preferences.changesRequested },
                set: { controller.preferences.changesRequested = $0 }
            ))
        }
        .formStyle(.grouped)
    }
}

private struct SourcesSettingsView: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sources")
                    .font(.headline)
                Spacer()
                if controller.isRefreshingSources {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 20, height: 20)
                }
                Button {
                    controller.refreshSources()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(controller.isRefreshingSources || controller.state.authStatus != .signedIn)
                .help("Refresh sources")
                .accessibilityLabel("Refresh sources")
            }

            SourceHeaderRow()

            if controller.sourceCatalog.owners.isEmpty {
                Text(controller.state.authStatus == .signedIn ? "No sources found." : "Sign in to GitHub to manage sources.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 360, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.sourceCatalog.owners) { owner in
                            OwnerSourceSettingsSection(
                                owner: owner,
                                controller: controller
                            )
                            Divider()
                        }
                    }
                }
            }

            if let error = controller.sourceErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            controller.refreshSources()
        }
    }
}

private struct SourceHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Owner / Repository")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Notifications")
                .frame(width: SourceSettingsLayout.columnWidth)
            Text("My PRs")
                .frame(width: SourceSettingsLayout.columnWidth)
            Text("Reviews")
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
                OwnerSourceSettingsRow(owner: owner.owner, controller: controller)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct OwnerSourceSettingsRow: View {
    let owner: String
    @ObservedObject var controller: DashboardController

    var body: some View {
        let preferences = controller.sourcePreferences.ownerPreferences(for: owner)
        HStack(spacing: 8) {
            Text(owner)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityLabel("\(owner), notifications \(preferences.notifications ? "on" : "off"), My PRs \(preferences.myPullRequests ? "on" : "off"), reviews \(preferences.reviewRequests ? "on" : "off")")
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

private struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MergeHawk")
                .font(.title2.weight(.semibold))
            Text("Native macOS menu bar dashboard for GitHub pull requests.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
