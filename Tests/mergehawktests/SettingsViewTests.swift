@testable import mergehawk
import CoreGraphics
import mergehawkcore

let mergehawkSettingsTabsTest: Void = {
    precondition(SettingsTab.allCases.map(\.title) == [
        "General",
        "GitHub",
        "Notifications",
        "Sources",
    ])
    precondition(SettingsTab.github.systemImage == "person.crop.circle.badge.checkmark")
    precondition(SettingsTab.notifications.systemImage == "bell")
    precondition(SettingsTab.sources.systemImage == "tray.full")
    precondition(SettingsTab.defaultWindowSize == CGSize(width: 560, height: 580))
    precondition(SettingsTabLayout.topPadding == 8)
    precondition(SettingsTabLayout.titleSize == 14)
    precondition(SettingsTabLayout.iconSize == 18)
    precondition(SettingsTabLayout.labelSize == 11)
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
}()

private func sourceCatalogEntries(_ catalog: SourceCatalog) -> [String] {
    catalog.owners.flatMap { owner in
        owner.repositories.map(\.identity.nameWithOwner)
    }
}
