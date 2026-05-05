import SwiftUI
import VCDashCore

enum SettingsTab: String, CaseIterable, Hashable {
    case general
    case github
    case notifications
    case display
    case about

    static let defaultWindowSize = CGSize(width: 600, height: 520)

    var title: String {
        switch self {
        case .general: "General"
        case .github: "GitHub"
        case .notifications: "Notifications"
        case .display: "Display"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .github: "person.crop.circle.badge.checkmark"
        case .notifications: "bell"
        case .display: "menubar.rectangle"
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
                .padding(.top, 12)
                .padding(.bottom, 12)

            Divider()

            selectedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            width: SettingsTab.defaultWindowSize.width,
            height: SettingsTab.defaultWindowSize.height
        )
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
        case .display:
            DisplaySettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        VStack(spacing: 12) {
            Text(selection.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        selection = tab
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 25, weight: .semibold))
                                .frame(height: 28)
                            Text(tab.title)
                                .font(.callout.weight(.semibold))
                        }
                        .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                        .frame(width: 92, height: 74)
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

private struct DisplaySettingsView: View {
    var body: some View {
        Form {
            Toggle("Show attention count in menu bar", isOn: .constant(true))
                .disabled(true)
            Toggle("Use compact rows", isOn: .constant(true))
                .disabled(true)
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
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
