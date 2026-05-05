import SwiftUI
import VCDashCore

enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case github
    case notifications
    case about

    static let defaultWindowSize = CGSize(width: 460, height: 560)

    var title: String {
        switch self {
        case .general: "General"
        case .github: "GitHub"
        case .notifications: "Notifications"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .github: "person.crop.circle.badge.checkmark"
        case .notifications: "bell"
        case .about: "info.circle"
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var controller: DashboardController
    @State private var selection = SettingsTab.general

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
    @FocusState private var tokenFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.state.authStatus == .signedIn {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Signed in")
                        .font(.headline)
                    Text(controller.accountLabel)
                        .foregroundStyle(.secondary)
                }
                Button("Sign Out", role: .destructive) {
                    controller.signOut()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Personal access token")
                        .font(.headline)
                    SecureField("github_pat_...", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .focused($tokenFieldFocused)
                        .onSubmit {
                            connect()
                        }
                    Text("Fine-grained PATs need read access for metadata, pull requests, issues, and actions on the repositories VC Dash monitors.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Connect") {
                        connect()
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
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
            if controller.state.authStatus != .signedIn {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    tokenFieldFocused = true
                }
            }
        }
    }

    private func connect() {
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

private struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VC Dash")
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
