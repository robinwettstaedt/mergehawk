import mergehawkcore
import SwiftUI

/// Every string of the ignore settings, and the bot mute help that points to them.
enum IgnoredAuthorSettingsCopy {
    static let botsTitle = "Ignore PRs opened by bots"
    static let botsHelp = "Ignored PRs leave your lists and counts, and you get no notifications about them, review requests included. Covers GitHub bots such as Dependabot, Renovate and Copilot."
    static let accountsTitle = "Ignored accounts"
    static let accountsHelp = "PRs opened by these GitHub users are ignored: they leave your lists and counts, and you get no notifications about them. Their comments on other PRs still notify you."
    static let placeholder = "GitHub username"
    static let add = "Add"
    static let edit = "Edit"
    static let emptyList = "No ignored accounts"
    static let muteBotNotificationsHelp = "Mutes new comments and reviews by bots on PRs you still see. Existing notifications remain. To ignore bot PRs entirely, turn on Ignore PRs opened by bots in Sources."

    static func countText(_ count: Int) -> String {
        switch count {
        case 0: "None"
        case 1: "1 account"
        default: "\(count) accounts"
        }
    }

    static func removeLabel(_ login: String) -> String {
        "Remove \(login)"
    }
}

/// The two ignore rows of the Sources header: the bots switch and the ignored accounts summary with its editor.
struct IgnoredAuthorSettingsRows: View {
    @ObservedObject var controller: DashboardController
    @State private var isEditingAccounts = false

    var body: some View {
        // The info icons stay outside the Toggle label: their tooltips never showed from inside the label.
        HStack(spacing: 4) {
            Text(IgnoredAuthorSettingsCopy.botsTitle)
            infoIcon(IgnoredAuthorSettingsCopy.botsHelp)
            Spacer()
            Toggle(IgnoredAuthorSettingsCopy.botsTitle, isOn: $controller.ignoresBotPullRequests)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityHint(IgnoredAuthorSettingsCopy.botsHelp)
        }
        HStack(spacing: 4) {
            Text(IgnoredAuthorSettingsCopy.accountsTitle)
            infoIcon(IgnoredAuthorSettingsCopy.accountsHelp)
            Spacer()
            Text(IgnoredAuthorSettingsCopy.countText(controller.ignoredAccounts.count))
                .foregroundStyle(.secondary)
            Button(IgnoredAuthorSettingsCopy.edit) {
                isEditingAccounts = true
            }
            .controlSize(.small)
            .accessibilityHint(IgnoredAuthorSettingsCopy.accountsHelp)
            .popover(isPresented: $isEditingAccounts, arrowEdge: .bottom) {
                IgnoredAccountsEditor(controller: controller)
            }
        }
    }

    private func infoIcon(_ help: String) -> some View {
        Image(systemName: "info.circle")
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityHidden(true)
    }
}

/// The ignored accounts editor: an add field and the accounts in the order they were added.
struct IgnoredAccountsEditor: View {
    @ObservedObject var controller: DashboardController
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField(IgnoredAuthorSettingsCopy.placeholder, text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button(IgnoredAuthorSettingsCopy.add, action: add)
                    .disabled(!controller.canAddIgnoredAccount(input))
            }
            Divider()
            if controller.ignoredAccounts.isEmpty {
                Text(IgnoredAuthorSettingsCopy.emptyList)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(controller.ignoredAccounts, id: \.self) { login in
                            HStack(spacing: 6) {
                                Text(login)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                Button {
                                    controller.removeIgnoredAccount(login)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(IgnoredAuthorSettingsCopy.removeLabel(login))
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func add() {
        if controller.addIgnoredAccount(input) {
            input = ""
        }
    }
}
