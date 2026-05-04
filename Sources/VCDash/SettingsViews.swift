import SwiftUI
import VCDashCore

struct SettingsRootView: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        TabView {
            GeneralSettingsView(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            GitHubSettingsView(controller: controller)
                .tabItem { Label("GitHub", systemImage: "person.crop.circle.badge.checkmark") }
            NotificationSettingsView(controller: controller)
                .tabItem { Label("Notifications", systemImage: "bell") }
            DisplaySettingsView()
                .tabItem { Label("Display", systemImage: "menubar.rectangle") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 380)
        .padding(20)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var controller: DashboardController

    var body: some View {
        Form {
            LabeledContent("Source", value: controller.sourceLabel)
            LabeledContent("Account", value: controller.accountLabel)
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
