@testable import mergehawk
import mergehawkcore
import XCTest

final class SettingsViewTests: XCTestCase {
    func testSourceCatalogSearchTrimsAndMatchesOwnerRepositoryOrCombinedName() {
        let catalog = makeCatalog()

        XCTAssertEqual(sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "")), [
            "acme/mergehawk",
            "acme/website",
            "openai/codex",
            "openai/swift-tools",
        ])
        XCTAssertEqual(sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "  OPENAI\n")), [
            "openai/codex",
            "openai/swift-tools",
        ])
        XCTAssertEqual(
            sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "merge")),
            ["acme/mergehawk"]
        )
        XCTAssertEqual(
            sourceCatalogEntries(SourceCatalogSearch.filteredCatalog(catalog, query: "acme/web")),
            ["acme/website"]
        )
    }

    func testSourceCatalogSearchReportsEmptyResultsAndCountsFilteredSources() {
        let catalog = makeCatalog()
        let missing = SourceCatalogSearch.filteredCatalog(catalog, query: "missing")
        let filtered = SourceCatalogSearch.filteredCatalog(catalog, query: "merge")

        XCTAssertTrue(missing.owners.isEmpty)
        XCTAssertEqual(SourceCatalogSearch.sourceCount(catalog), 4)
        XCTAssertEqual(SourceCatalogSearch.sourceCount(filtered), 1)
        XCTAssertEqual(SourceCatalogSearch.sourceCount(SourceCatalog(repositories: [], accountLogin: "rw")), 0)
        XCTAssertEqual(CountSearchPresentation.countLabel(for: 1, singular: "source", plural: "sources"), "1 source")
        XCTAssertEqual(CountSearchPresentation.countLabel(for: 4, singular: "source", plural: "sources"), "4 sources")
    }

    private func makeCatalog() -> SourceCatalog {
        SourceCatalog(owners: [
            OwnerSource(owner: "acme", repositories: [
                RepositorySource(owner: "acme", name: "mergehawk"),
                RepositorySource(owner: "acme", name: "website"),
            ]),
            OwnerSource(owner: "openai", repositories: [
                RepositorySource(owner: "openai", name: "codex"),
                RepositorySource(owner: "openai", name: "swift-tools"),
            ]),
        ])
    }

    private func sourceCatalogEntries(_ catalog: SourceCatalog) -> [String] {
        catalog.owners.flatMap { owner in
            owner.repositories.map(\.identity.nameWithOwner)
        }
    }
}
