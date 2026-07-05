@testable import mergehawk
import AppKit
import CoreGraphics
import mergehawkcore

let mergehawkSettingsTabsTest: Void = {
    precondition(SettingsTab.allCases.map(\.title) == [
        "General",
        "GitHub",
        "Notifications",
        "Sources",
        "About",
    ])
    precondition(SettingsTab.github.systemImage == "person.crop.circle.badge.checkmark")
    precondition(SettingsTab.notifications.systemImage == "bell")
    precondition(SettingsTab.sources.systemImage == "tray.full")
    precondition(SettingsTab.about.systemImage == "info.circle")
    precondition(SettingsTab.defaultWindowSize == CGSize(width: 500, height: 700))
    precondition(SettingsTabLayout.topPadding == 8)
    precondition(SettingsTabLayout.titleSize == 14)
    precondition(SettingsTabLayout.iconSize == 18)
    precondition(SettingsTabLayout.labelSize == 11)
}()

let mergehawkNotificationMatrixSettingsModelTest: Void = {
    precondition(PullRequestNotificationRelationship.allCases == [
        .authored,
        .assigned,
        .directReviewRequest,
        .teamReviewRequest,
    ])
    precondition(PullRequestNotificationActivity.allCases == [
        .comments,
        .reviewActivity,
        .ciFailures,
        .relationshipChanges,
        .otherCommits,
    ])
}()

let mergehawkSourceSettingsCopyTest: Void = {
    precondition(SourceSettingsCopy.authoredTitle == "Authored")
    precondition(SourceSettingsCopy.requestedTitle == "Requested")
}()

let mergehawkAboutSettingsCopyTest: Void = {
    precondition(AboutPanelContent.appName == "MergeHawk")
    precondition(AboutPanelContent.credits == "Eyes on the pull requests that matter to you.")
    precondition(AboutPanelContent.footer == "© 2026 Robin Wettstädt. MIT license.")
    precondition(AboutPanelContent.links.map(\.title) == ["GitHub", "Website"])
    precondition(AboutPanelContent.links.map(\.url.absoluteString) == [
        "https://github.com/robinwettstaedt/mergehawk",
        "https://mergehawk.dev",
    ])
    precondition(AboutPanelContent.versionText(bundle: .main) == "Version 0.1.0 (1)")
    precondition(AboutPanelContent.logoImage()?.size == NSSize(width: 128, height: 128))
}()

let mergehawkGeneralUpdateSettingsCopyTest: Void = {
    precondition(GeneralUpdateCopy.updateApplicationTitle == "Update application")
    precondition(GeneralUpdateCopy.automaticChecksTitle == "Automatically check for updates")
    precondition(GeneralUpdateCopy.manualCheckTitle == "Check for Updates...")
    precondition(GeneralUpdateCopy.automaticChecksHelp == "MergeHawk checks GitHub Releases in the background and lets you install newer versions.")
}()

let mergehawkSourceCatalogSearchTest: Void = {
    let catalog = SourceCatalog(owners: [
        OwnerSource(owner: "acme", repositories: [
            RepositorySource(owner: "acme", name: "mergehawk"),
            RepositorySource(owner: "acme", name: "website"),
        ]),
        OwnerSource(owner: "openai", repositories: [
            RepositorySource(owner: "openai", name: "codex"),
            RepositorySource(owner: "openai", name: "swift-tools"),
        ]),
    ])

    precondition(sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "")) == [
        "acme/mergehawk",
        "acme/website",
        "openai/codex",
        "openai/swift-tools",
    ])
    precondition(sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "   ")) == [
        "acme/mergehawk",
        "acme/website",
        "openai/codex",
        "openai/swift-tools",
    ])
    precondition(sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "  OPENAI\n")) == [
        "openai/codex",
        "openai/swift-tools",
    ])
    precondition(sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "merge")) == [
        "acme/mergehawk",
    ])
    precondition(sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "acme/web")) == [
        "acme/website",
    ])
    precondition(SourceCatalogSearch.filteredCatalog(catalog, query: "missing").owners.isEmpty)
    precondition(SourceCatalogSearch.sourceCount(catalog) == 4)
    precondition(SourceCatalogSearch.sourceCount(SourceCatalogSearch.filteredCatalog(catalog, query: "merge")) == 1)
    precondition(SourceCatalogSearch.sourceCount(SourceCatalog(repositories: [], accountLogin: "rw")) == 0)
    precondition(CountSearchPresentation.countLabel(for: 1, singular: "source", plural: "sources") == "1 source")
    precondition(CountSearchPresentation.countLabel(for: 4, singular: "source", plural: "sources") == "4 sources")
}()

private func sourceCatalogEntries(_ catalog: SourceCatalog) -> [String] {
    catalog.owners.flatMap { owner in
        owner.repositories.map(\.identity.nameWithOwner)
    }
}
