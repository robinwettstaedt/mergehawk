import mergehawkcore
import XCTest

final class GitHubMentionParserTests: XCTestCase {
    /// Captured from a provider-rendered IssueComment on a dedicated test fixture.
    private static let providerComment = """
    <p dir="auto">MER73 20260926T095229Z-92f9c9 C1: <a class="user-mention notranslate" data-hovercard-type="user" \
    data-hovercard-url="/users/mergehawk-test-env/hovercard" data-octo-click="hovercard-link-click" \
    data-octo-dimensions="link_type:self" href="https://github.com/mergehawk-test-env">@mergehawk-test-env</a> \
    please inspect this synthetic fixture.</p>
    """

    private func mention(_ login: String, classes: String = "user-mention notranslate", hovercard: String? = "user", href: String? = nil) -> String {
        let hovercardAttribute = hovercard.map { " data-hovercard-type=\"\($0)\"" } ?? ""
        let hrefValue = href ?? "https://github.com/\(login)"
        return "<a class=\"\(classes)\"\(hovercardAttribute) href=\"\(hrefValue)\">@\(login)</a>"
    }

    private func matches(_ html: String, viewer: String = "mergehawk-test-env") throws -> Bool {
        try GitHubMentionParser.mentionsUser(viewer, inRenderedHTML: html)
    }

    func testProviderRenderedMentionMatchesViewerDespiteCasingAndExtraClasses() throws {
        XCTAssertTrue(try matches(Self.providerComment))
        XCTAssertTrue(try matches(Self.providerComment, viewer: "MergeHawk-Test-Env"))
        XCTAssertTrue(try matches("<p>\(mention("MERGEHAWK-test-env", classes: "notranslate user-mention extra"))</p>"))
        XCTAssertTrue(try matches("<p>\(mention("mergehawk-test-env", href: "https://github.com/mergehawk-test-env/"))</p>"))
    }

    func testOtherUsersPrefixesTeamsProfileLinksAndPlainTextDoNotMatch() throws {
        XCTAssertFalse(try matches(Self.providerComment, viewer: "someone-else"))
        XCTAssertFalse(try matches(Self.providerComment, viewer: "mergehawk-test"))
        XCTAssertFalse(try matches("<p>\(mention("mergehawk-test-env-2"))</p>"))
        XCTAssertFalse(try matches("""
        <p><a class="team-mention js-team-mention notranslate" data-hovercard-type="team" \
        href="https://github.com/orgs/acme/teams/mergehawk-test-env">@acme/mergehawk-test-env</a></p>
        """))
        XCTAssertFalse(try matches("<p><a href=\"https://github.com/mergehawk-test-env\">profile</a></p>"))
        XCTAssertFalse(try matches("<p>Ping @mergehawk-test-env about it.</p>"))
    }

    func testQuotedAndCodeMentionsAreExcludedButAnotherMentionStillMatches() throws {
        let direct = mention("mergehawk-test-env")
        XCTAssertFalse(try matches("<blockquote><blockquote><p>\(direct)</p></blockquote></blockquote>"))
        XCTAssertFalse(try matches("<p><code>\(direct)</code></p>"))
        XCTAssertFalse(try matches("<div class=\"highlight\"><pre><span>\(direct)</span></pre></div>"))
        XCTAssertTrue(try matches("<blockquote><p>\(direct)</p></blockquote><p>Reply to \(direct)</p>"))
        XCTAssertTrue(try matches("<pre><code>\(direct)</code></pre><p><strong>\(direct)</strong></p>"))
    }

    func testEntitiesNestedFormattingMultipleMentionsAndEmptyFragments() throws {
        XCTAssertTrue(try matches("<p>Tom &amp; Jerry &lt;3 <em><strong>\(mention("mergehawk-test-env"))</strong></em></p>"))
        XCTAssertTrue(try matches("<p>\(mention("alice")), \(mention("bob")) and \(mention("mergehawk-test-env"))</p>"))
        XCTAssertFalse(try matches("<p>\(mention("alice")) &amp; \(mention("bob"))</p>"))
        XCTAssertFalse(try matches(""))
        XCTAssertFalse(try matches("   "))
    }

    func testAnchorsMissingAnyProviderSignalDoNotQualify() throws {
        XCTAssertFalse(try matches("<p>\(mention("mergehawk-test-env", classes: "notranslate"))</p>"))
        XCTAssertFalse(try matches("<p>\(mention("mergehawk-test-env", classes: "user-mentioned"))</p>"))
        XCTAssertFalse(try matches("<p>\(mention("mergehawk-test-env", hovercard: nil))</p>"))
        XCTAssertFalse(try matches("<p>\(mention("mergehawk-test-env", hovercard: "organization"))</p>"))
        for href in [
            "http://github.com/mergehawk-test-env",
            "https://gist.github.com/mergehawk-test-env",
            "https://example.com/mergehawk-test-env",
            "https://github.com/mergehawk-test-env/repo",
            "https://github.com/mergehawk-test-env?tab=repositories",
            "https://github.com/mergehawk-test-env#top",
            "/mergehawk-test-env",
            "",
        ] {
            XCTAssertFalse(try matches("<p>\(mention("mergehawk-test-env", href: href))</p>"), href)
        }
        XCTAssertFalse(try matches("<p><span class=\"user-mention\" data-hovercard-type=\"user\">@mergehawk-test-env</span></p>"))
    }
}
