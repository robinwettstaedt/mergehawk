import Foundation
import SwiftSoup

/// Classifies GitHub's rendered comment HTML for a direct mention of one user.
///
/// Only GitHub's own user-mention anchors count: the anchor must carry the `user-mention` class, a user
/// hovercard, and a canonical `https://github.com/<login>` profile link. Anchors inside quotes or code are
/// ignored, and no display text or Markdown is scanned.
public enum GitHubMentionParser {
    private static let excludedAncestorTags: Set<String> = ["blockquote", "pre", "code"]

    public static func mentionsUser(_ login: String, inRenderedHTML html: String) throws -> Bool {
        guard !login.isEmpty, !html.isEmpty else {
            return false
        }
        let document = try SwiftSoup.parseBodyFragment(html)
        for anchor in try document.select("a") {
            guard
                anchor.hasClass("user-mention"),
                try anchor.attr("data-hovercard-type") == "user",
                profileLogin(fromHref: try anchor.attr("href"))?.caseInsensitiveCompare(login) == .orderedSame,
                !anchor.parents().contains(where: { excludedAncestorTags.contains($0.tagNameNormal()) })
            else {
                continue
            }
            return true
        }
        return false
    }

    private static func profileLogin(fromHref href: String) -> String? {
        guard
            let components = URLComponents(string: href),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == "github.com",
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.query == nil,
            components.fragment == nil
        else {
            return nil
        }
        var path = components.path
        guard path.hasPrefix("/") else {
            return nil
        }
        path.removeFirst()
        if path.hasSuffix("/") {
            path.removeLast()
        }
        guard !path.isEmpty, !path.contains("/") else {
            return nil
        }
        return path
    }
}
