import AppKit
import SwiftUI
import mergehawkcore

enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case github
    case notifications
    case sources
    case teams
    case about

    static let defaultWindowSize = CGSize(width: 500, height: 700)

    var title: String {
        switch self {
        case .general: "General"
        case .github: "GitHub"
        case .notifications: "Notifications"
        case .sources: "Sources"
        case .teams: "Teams"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .github: "person.crop.circle.badge.checkmark"
        case .notifications: "bell"
        case .sources: "tray.full"
        case .teams: "person.3"
        case .about: "info.circle"
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var controller: DashboardController
    @ObservedObject var settingsWindowState: SettingsWindowState
    @ObservedObject var softwareUpdateController: SoftwareUpdateController
    private let initialSourcesSearchState: ExpandableSearchState

    @MainActor init(
        controller: DashboardController,
        settingsWindowState: SettingsWindowState,
        softwareUpdateController: SoftwareUpdateController,
        initialSourcesSearchState: ExpandableSearchState = ExpandableSearchState()
    ) {
        self.controller = controller
        self.settingsWindowState = settingsWindowState
        self.softwareUpdateController = softwareUpdateController
        self.initialSourcesSearchState = initialSourcesSearchState
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $settingsWindowState.selection)
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
        .background(settingsTabShortcuts)
    }

    private var settingsTabShortcuts: some View {
        ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element) { index, tab in
            Button("") {
                settingsWindowState.selection = tab
            }
            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            .hidden()
        }
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch settingsWindowState.selection {
        case .general:
            GeneralSettingsView(
                controller: controller,
                softwareUpdateController: softwareUpdateController
            )
        case .github:
            GitHubSettingsView(controller: controller)
        case .notifications:
            NotificationSettingsView(controller: controller)
        case .sources:
            SourcesSettingsView(
                controller: controller,
                initialSearchState: initialSourcesSearchState
            )
        case .teams:
            TeamsSettingsView(controller: controller)
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
    static let tabWidth: CGFloat = 72
    static let tabHeight: CGFloat = 58
    static let titleSize: CGFloat = 14
    static let iconSize: CGFloat = 18
    static let iconHeight: CGFloat = 20
    static let labelSize: CGFloat = 11
}

private struct SettingsSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let darkFillOpacity: Double
    var showsBorder = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        content
            .background(fill, in: shape)
            .overlay {
                if showsBorder {
                    shape.stroke(border, lineWidth: 1)
                }
            }
    }

    private var fill: Color {
        colorScheme == .dark
            ? Color.gray.opacity(darkFillOpacity)
            : Color.black.opacity(0.035)
    }

    private var border: Color {
        colorScheme == .dark
            ? Color.gray.opacity(0.22)
            : Color.black.opacity(0.10)
    }
}

private extension View {
    func settingsSurface(darkFillOpacity: Double, showsBorder: Bool = false) -> some View {
        modifier(SettingsSurface(darkFillOpacity: darkFillOpacity, showsBorder: showsBorder))
    }
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
                            tabIcon(for: tab)
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

    @ViewBuilder
    private func tabIcon(for tab: SettingsTab) -> some View {
        if tab == .github, let mark = GitHubSignInView.gitHubMarkImage {
            Image(nsImage: mark)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: SettingsTabLayout.iconSize, height: SettingsTabLayout.iconSize)
        } else {
            Image(systemName: tab.systemImage)
                .font(.system(size: SettingsTabLayout.iconSize, weight: .semibold))
        }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var controller: DashboardController
    @ObservedObject var softwareUpdateController: SoftwareUpdateController

    var body: some View {
        Form {
            Toggle("Start at login", isOn: Binding(
                get: { controller.startsAtLogin },
                set: { controller.setStartsAtLogin($0) }
            ))
            if let error = controller.launchAtLoginErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Source", value: controller.sourceLabel)
            LabeledContent("Account", value: controller.accountLabel)
            Picker("Refresh Interval", selection: $controller.refreshIntervalMinutes) {
                ForEach(controller.refreshIntervalOptions, id: \.self) { minutes in
                    Text("\(minutes) min").tag(minutes)
                }
            }
            .pickerStyle(.segmented)
            Picker("Menu Size", selection: $controller.menuSize) {
                ForEach(MenuSize.allCases, id: \.self) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.segmented)
            Text(GeneralMenuSizeCopy.reductionNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            if softwareUpdateController.isAvailable {
                HStack {
                    Text(GeneralUpdateCopy.updateApplicationTitle)
                    Spacer()
                    Button {
                        softwareUpdateController.checkForUpdates()
                    } label: {
                        Text(GeneralUpdateCopy.manualCheckTitle)
                            .frame(minWidth: 150)
                    }
                    .disabled(!softwareUpdateController.canCheckForUpdates)
                }

                Toggle(isOn: Binding(
                    get: {
                        softwareUpdateController.automaticallyChecksForUpdates
                    },
                    set: { isEnabled in
                        softwareUpdateController.automaticallyChecksForUpdates = isEnabled
                    }
                )) {
                    HStack(spacing: 8) {
                        Text(GeneralUpdateCopy.automaticChecksTitle)
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .help(GeneralUpdateCopy.automaticChecksHelp)
                    }
                }
                .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            Form {
                Section {
                    Text("Try pressing ")
                        + Text("⌘1").foregroundColor(.accentColor).fontWeight(.semibold)
                        + Text("–").foregroundColor(.accentColor).fontWeight(.semibold)
                        + Text("⌘5").foregroundColor(.accentColor).fontWeight(.semibold)
                        + Text(" to switch tabs in MergeHawk!")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 64)
        }
    }
}

enum GeneralMenuSizeCopy {
    static let reductionNote = "The menu may be reduced to fit smaller displays."
}

enum GeneralUpdateCopy {
    static let updateApplicationTitle = "Update application"
    static let automaticChecksTitle = "Automatically check for updates"
    static let automaticChecksHelp = "MergeHawk checks GitHub Releases in the background and lets you install newer versions."
    static let manualCheckTitle = "Check for Updates..."
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
    @State private var selectedSignInMode: SignInMode = .app
    @FocusState private var tokenFieldFocused: Bool

    private enum SignInMode {
        case app, pat
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if controller.state.authStatus == .signedIn {
                        VStack(spacing: 20) {
                            VStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.green)
                                VStack(spacing: 3) {
                                    Text(controller.accountLabel)
                                        .font(.title3.weight(.semibold))
                                    Text(controller.authMethod.label)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                Button("Sign Out", role: .destructive) {
                                    controller.signOut()
                                }
                                .padding(.top, 2)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)

                            if controller.authMethod == .oauth {
                                GitHubAppAccessNotes(showsInstallLink: false)
                            }
                        }
                    } else {
                        VStack(spacing: 16) {
                            signInModeSelector
                                .disabled(controller.isSigningInWithToken)

                            if selectedSignInMode == .app {
                                if let challenge = controller.deviceFlowChallenge {
                                    DeviceFlowPendingSignInView(controller: controller, challenge: challenge)
                                } else {
                                    VStack(spacing: 16) {
                                        HStack(spacing: 8) {
                                            Button {
                                                connectWithGitHub()
                                            } label: {
                                                HStack(spacing: 6) {
                                                    if let mark = GitHubSignInView.gitHubMarkImage {
                                                        Image(nsImage: mark)
                                                            .resizable()
                                                            .renderingMode(.template)
                                                            .frame(width: 14, height: 14)
                                                    }
                                                    Text("Sign in with GitHub")
                                                        .font(.system(size: 13, weight: .semibold))
                                                }
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 16)
                                                .frame(height: 30)
                                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(controller.isRequestingDeviceCode)

                                            if controller.isRequestingDeviceCode {
                                                ProgressView()
                                                    .controlSize(.small)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 8)

                                        if let error = controller.errorMessage {
                                            Text(error)
                                                .font(.caption)
                                                .foregroundStyle(.red)
                                                .frame(maxWidth: .infinity, alignment: .center)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }

                                        GitHubAppAccessNotes(showsInstallLink: true)
                                    }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    PATContextNotes()

                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 8) {
                                            SecureField("github_pat_... or ghp_...", text: $token)
                                                .textFieldStyle(.roundedBorder)
                                                .controlSize(.large)
                                                .focused($tokenFieldFocused)
                                                .onSubmit { connectWithToken() }
                                                .disabled(controller.isSigningInWithToken)

                                            ZStack {
                                                Button {
                                                    connectWithToken()
                                                } label: {
                                                    Text("Connect")
                                                        .opacity(controller.isSigningInWithToken ? 0 : 1)
                                                        .font(.system(size: 13, weight: .semibold))
                                                        .foregroundStyle(.white)
                                                        .padding(.horizontal, 16)
                                                        .frame(height: 30)
                                                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(
                                                    token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                        || controller.isSigningInWithToken
                                                )
                                                .opacity(
                                                    token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                        && !controller.isSigningInWithToken ? 0.45 : 1.0
                                                )
                                                .accessibilityLabel(controller.isSigningInWithToken ? "Connecting…" : "Connect")

                                                if controller.isSigningInWithToken {
                                                    PATSignInProgressView()
                                                        .allowsHitTesting(false)
                                                        .accessibilityHidden(true)
                                                }
                                            }
                                        }

                                        Link(destination: URL(string: "https://github.com/settings/tokens/new")!) {
                                            HStack(spacing: 3) {
                                                Text("Create a classic token on GitHub")
                                                Image(systemName: "arrow.up.right")
                                                    .font(.system(size: 9, weight: .semibold))
                                            }
                                            .font(.caption)
                                        }

                                        Text(controller.errorMessage ?? "")
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .frame(minHeight: 14)
                                            .opacity(controller.errorMessage != nil ? 1 : 0)
                                    }
                                    .padding(.vertical, 8)

                                    PATAccessNotes()
                                }
                            }
                        }
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
            if controller.openGitHubSettingsInPATMode {
                selectedSignInMode = .pat
                controller.openGitHubSettingsInPATMode = false
            }
            if controller.state.authStatus != .signedIn, selectedSignInMode == .pat {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    tokenFieldFocused = true
                }
            }
        }
    }

    private var signInModeSelector: some View {
        HStack(spacing: 0) {
            signInModeButton("GitHub App", mode: .app)
            signInModeButton("Personal Access Token", mode: .pat)
        }
        .padding(3)
        .settingsSurface(darkFillOpacity: 0.18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sign-in method")
    }

    private func signInModeButton(_ title: String, mode: SignInMode) -> some View {
        Button {
            selectedSignInMode = mode
        } label: {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(selectedSignInMode == mode ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background {
                    if selectedSignInMode == mode {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.thinMaterial)
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedSignInMode == mode ? .isSelected : [])
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

private struct PATSignInProgressView: View {
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

struct NotificationSettingsView: View {
    private static let muteBotNotificationsHelp = "Applies to new comments and reviews from accounts GitHub identifies as bots, across all repositories. Existing notifications remain."

    @ObservedObject var controller: DashboardController

    var body: some View {
        Form {
            Toggle("macOS local notifications", isOn: $controller.macOSLocalNotificationsEnabled)
            // The info icon stays outside the Toggle label: its tooltip never showed from inside the label.
            HStack(spacing: 4) {
                Text("Mute bot comment and review notifications")
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(Self.muteBotNotificationsHelp)
                    .accessibilityHidden(true)
                Spacer()
                Toggle("Mute bot comment and review notifications", isOn: $controller.muteBotNotifications)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityHint(Self.muteBotNotificationsHelp)
            }
            Section("Pull request notifications") {
                // Laid out like the comment table below so both tables share their relationship columns.
                VStack(alignment: .leading, spacing: 8) {
                    NotificationRelationshipHeader()

                    Divider()

                    VStack(alignment: .leading, spacing: NotificationMatrixLayout.rowSpacing) {
                        ForEach(PullRequestNotificationActivity.allCases, id: \.self) { activity in
                            HStack(spacing: NotificationMatrixLayout.columnSpacing) {
                                Text(activity.rowTitle)
                                    .lineLimit(2)
                                    .frame(width: NotificationMatrixLayout.labelColumnWidth, alignment: .leading)
                                ForEach(PullRequestNotificationRelationship.allCases, id: \.self) { relationship in
                                    if NotificationMatrixLayout.showsToggle(relationship: relationship, activity: activity) {
                                        Toggle("", isOn: matrixBinding(relationship: relationship, activity: activity))
                                            .labelsHidden()
                                            .toggleStyle(.checkbox)
                                            .frame(width: NotificationMatrixLayout.relationshipColumnWidth)
                                            .accessibilityLabel(
                                                NotificationMatrixLayout.checkboxAccessibilityLabel(relationship: relationship, activity: activity)
                                            )
                                    } else {
                                        Text("—")
                                            .foregroundStyle(.secondary)
                                            .frame(width: NotificationMatrixLayout.relationshipColumnWidth)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .frame(height: NotificationMatrixLayout.rowHeight)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    NotificationRelationshipHeader()

                    Divider()

                    HStack(alignment: .top, spacing: NotificationMatrixLayout.columnSpacing) {
                        VStack(alignment: .leading, spacing: NotificationMatrixLayout.rowSpacing) {
                            ForEach(CommentNotificationMode.allCases, id: \.self) { mode in
                                HStack(spacing: 4) {
                                    Text(mode.title)
                                        .lineLimit(2)
                                    if let help = mode.help {
                                        Image(systemName: "info.circle")
                                            .foregroundStyle(.secondary)
                                            .help(help)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(
                                    width: NotificationMatrixLayout.labelColumnWidth,
                                    height: NotificationMatrixLayout.rowHeight,
                                    alignment: .leading
                                )
                            }
                        }
                        ForEach(PullRequestNotificationRelationship.allCases, id: \.self) { relationship in
                            CommentModeRadioGroup(
                                relationship: relationship,
                                selection: commentModeBinding(for: relationship)
                            )
                            .frame(
                                width: NotificationMatrixLayout.relationshipColumnWidth,
                                height: NotificationMatrixLayout.commentModeColumnHeight
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } header: {
                Text("Comment notifications")
            }
        }
        .formStyle(.grouped)
    }

    func commentModeBinding(for relationship: PullRequestNotificationRelationship) -> Binding<CommentNotificationMode> {
        Binding(
            get: { controller.preferences.commentModes.mode(for: relationship) },
            set: { mode in
                var preferences = controller.preferences
                preferences.commentModes.set(mode, for: relationship)
                controller.preferences = preferences
            }
        )
    }

    func matrixBinding(
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
                case .reviewActivity:
                    activityPreferences.reviewActivity = isEnabled
                case .ciFailures:
                    activityPreferences.ciFailures = isEnabled
                case .relationshipChanges:
                    activityPreferences.relationshipChanges = isEnabled
                case .readyForReview:
                    activityPreferences.readyForReview = isEnabled
                }
                preferences.set(activityPreferences, for: relationship)
                controller.preferences = preferences
            }
        )
    }
}

/// The relationship columns shared by both notification tables, bottom-aligned on one header level.
private struct NotificationRelationshipHeader: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: NotificationMatrixLayout.columnSpacing) {
            Text("Notify me for")
                .frame(width: NotificationMatrixLayout.labelColumnWidth, alignment: .leading)
            ForEach(PullRequestNotificationRelationship.allCases, id: \.self) { relationship in
                Text(relationship.columnTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: NotificationMatrixLayout.relationshipColumnWidth)
                    .help(relationship.columnHelp)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// AppKit radio buttons sharing one superview and action, so they select exclusively, move with the arrow keys
/// under keyboard navigation, and read as one labeled radio group to assistive technologies.
struct CommentModeRadioGroup: NSViewRepresentable {
    let relationship: PullRequestNotificationRelationship
    @Binding var selection: CommentNotificationMode

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> RadioGroupView {
        let group = RadioGroupView()
        group.setAccessibilityLabel(NotificationMatrixLayout.commentModeAccessibilityLabel(for: relationship))
        for (index, mode) in CommentNotificationMode.allCases.enumerated() {
            let button = NSButton(radioButtonWithTitle: "", target: context.coordinator, action: #selector(Coordinator.select(_:)))
            button.tag = index
            button.setAccessibilityLabel(mode.title)
            button.toolTip = "\(relationship.title): \(mode.title)"
            if let help = mode.help {
                // The label's info icon is hidden from accessibility, so the radio button carries its explanation.
                button.setAccessibilityHelp(help)
            }
            group.addSubview(button)
        }
        return group
    }

    func updateNSView(_ group: RadioGroupView, context: Context) {
        context.coordinator.selection = $selection
        for case let button as NSButton in group.subviews {
            button.state = CommentNotificationMode.allCases[button.tag] == selection ? .on : .off
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<CommentNotificationMode>

        init(selection: Binding<CommentNotificationMode>) {
            self.selection = selection
        }

        @objc func select(_ sender: NSButton) {
            selection.wrappedValue = CommentNotificationMode.allCases[sender.tag]
        }
    }

    /// Stacks the radio buttons down the relationship column, each centered in its comment mode's row.
    final class RadioGroupView: NSView {
        override var isFlipped: Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }
        override func isAccessibilityElement() -> Bool { true }

        override func layout() {
            super.layout()
            let rowHeight = NotificationMatrixLayout.rowHeight
            let rowPitch = rowHeight + NotificationMatrixLayout.rowSpacing
            for case let button as NSButton in subviews {
                let size = button.fittingSize
                button.frame = CGRect(
                    x: ((bounds.width - size.width) / 2).rounded(),
                    y: (CGFloat(button.tag) * rowPitch + (rowHeight - size.height) / 2).rounded(),
                    width: size.width,
                    height: size.height
                )
            }
        }
    }
}

enum NotificationMatrixLayout {
    static let labelColumnWidth: CGFloat = 150
    static let relationshipColumnWidth: CGFloat = 56
    static let columnSpacing: CGFloat = 10
    /// Every row in both tables: tall enough for a label that wraps to two lines, so rows sit evenly spaced.
    static let rowHeight: CGFloat = 32
    /// The gap between rows in both tables, so a two-line label never touches its neighbours.
    static let rowSpacing: CGFloat = 8

    /// The comment table's label column and each relationship's radio group: every mode row and the gaps between them.
    static var commentModeColumnHeight: CGFloat {
        let rowCount = CGFloat(CommentNotificationMode.allCases.count)
        return rowCount * rowHeight + (rowCount - 1) * rowSpacing
    }

    /// The label column and the four relationship columns with the spacing before each.
    static var tableWidth: CGFloat {
        let columnCount = CGFloat(PullRequestNotificationRelationship.allCases.count)
        return labelColumnWidth + columnCount * (relationshipColumnWidth + columnSpacing)
    }

    /// Authored PRs have no New assignment or review request or Ready for review cell.
    static func showsToggle(
        relationship: PullRequestNotificationRelationship,
        activity: PullRequestNotificationActivity
    ) -> Bool {
        switch activity {
        case .relationshipChanges, .readyForReview:
            relationship != .authored
        case .reviewActivity, .ciFailures:
            true
        }
    }

    /// Names an upper-table checkbox by its relationship and update type.
    static func checkboxAccessibilityLabel(
        relationship: PullRequestNotificationRelationship,
        activity: PullRequestNotificationActivity
    ) -> String {
        "\(relationship.title) \(activity.accessibilityTitle)"
    }

    /// Names a relationship's comment-mode radio group, like the upper table's "<relationship> <activity>" checkboxes.
    static func commentModeAccessibilityLabel(for relationship: PullRequestNotificationRelationship) -> String {
        "\(relationship.title) comment notifications"
    }
}

extension PullRequestNotificationRelationship {
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

    var columnTitle: String {
        switch self {
        case .authored:
            "Authored"
        case .assigned:
            "Assigned"
        case .directReviewRequest:
            "Direct\nrequest"
        case .teamReviewRequest:
            "Team\nrequest"
        }
    }

    var columnHelp: String {
        switch self {
        case .authored:
            "PRs you opened"
        case .assigned:
            "PRs assigned to you"
        case .directReviewRequest:
            "Your review was requested by name"
        case .teamReviewRequest:
            "A team you belong to was requested"
        }
    }
}

extension CommentNotificationMode {
    static let mentionsAndThreadsHelp = "Mentions & threads you joined covers direct mentions of you and new comments in review threads where your published comments are still present."

    /// The explanation behind a mode's info icon, if it has one.
    var help: String? {
        self == .mentionsAndThreads ? Self.mentionsAndThreadsHelp : nil
    }

    var title: String {
        switch self {
        case .all:
            "All comments"
        case .mentionsAndThreads:
            "Mentions & threads you joined"
        case .off:
            "Off"
        }
    }
}

extension PullRequestNotificationActivity {
    var rowTitle: String {
        switch self {
        case .reviewActivity:
            "Review decisions"
        case .ciFailures:
            "CI failed"
        case .relationshipChanges:
            "New assignment or review request"
        case .readyForReview:
            "Ready for review"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .reviewActivity:
            "review decisions"
        case .ciFailures:
            "CI failures"
        case .relationshipChanges:
            "new assignment or review request"
        case .readyForReview:
            "ready for review"
        }
    }
}

private struct SourcesSettingsView: View {
    private static let hideArchivedRepositoriesHelp = "Hides PRs and notifications from repositories archived on GitHub."

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
                // The info icon stays outside the Toggle label: its tooltip never showed from inside the label.
                HStack(spacing: 4) {
                    Text("Hide archived repositories")
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help(Self.hideArchivedRepositoriesHelp)
                        .accessibilityHidden(true)
                    Spacer()
                    Toggle("Hide archived repositories", isOn: $controller.hideArchivedRepositories)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        // Matches the switch size grouped Forms use in the other settings tabs.
                        .controlSize(.mini)
                        .accessibilityHint(Self.hideArchivedRepositoriesHelp)
                }
                Divider()
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
            controller.refreshSourcesIfNeeded()
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

private struct TeamsSettingsView: View {
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

private struct GitHubAppAccessNotes: View {
    var showsInstallLink: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            noteRow(
                icon: "building.2",
                text: "Private organization repositories require the MergeHawk GitHub App to be installed on that organization or selected repositories."
            )
            if showsInstallLink {
                Divider()
                Link(destination: MergeHawkAuthDefaults.installURL) {
                    HStack(spacing: 4) {
                        Text("Install MergeHawk GitHub App")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .settingsSurface(darkFillOpacity: 0.14, showsBorder: true)
    }

    private func noteRow(icon: String, text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct PATContextNotes: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            noteRow(
                icon: "building.2",
                text: "Use this if your organization restricts OAuth apps."
            )
            Divider()
            noteRow(
                icon: "lock",
                text: "MergeHawk only requests read-only access — it never writes to your account."
            )
        }
        .settingsSurface(darkFillOpacity: 0.14, showsBorder: true)
    }

    private func noteRow(icon: String, text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct PATAccessNotes: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            noteRow(
                icon: "key",
                title: "Classic PAT",
                scopes: ["repo", "read:user", "read:org"],
                footer: "Supports PRs in repositories available to the token"
            )
            Divider()
            noteRow(
                icon: "key.viewfinder",
                title: "Fine-grained PAT",
                scopes: ["Metadata: Read-only", "Pull requests: Read-only", "Issues: Read-only", "Commit statuses: Read-only", "Checks: Read-only", "Members: Read-only (organization)"],
                footer: "Limit access to selected repositories"
            )
        }
        .settingsSurface(darkFillOpacity: 0.14, showsBorder: true)
    }

    private func noteRow(icon: String, title: String, isRecommended: Bool = false, scopes: [String], footer: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    if isRecommended {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(scopes, id: \.self) { scope in
                        Text(scope)
                            .font(.system(size: 10, design: .monospaced).weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct GitHubOAuthAccessButton: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        Button {
            controller.open(MergeHawkAuthDefaults.authorizedAppSettingsURL)
        } label: {
            HStack(spacing: 4) {
                Text("Manage GitHub App Authorization")
                Image(systemName: "arrow.up.right")
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
                Text(GitHubAppRepositoryAccessCopy.buttonTitle)
                Image(systemName: "arrow.up.right")
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
