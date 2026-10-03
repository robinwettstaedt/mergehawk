import Foundation
import XCTest

/// A guard against new menu code bypassing `MenuMetrics`; not proof that everything scales.
final class MenuMetricsGuardTests: XCTestCase {
    private static let textStyles = "(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)"
    private static let forbiddenPatterns: [NSRegularExpression] = [
        #"\.system\(size:"#,
        #"\.system\(\."# + textStyles + #"\b"#,
        #"\.font\(\."# + textStyles + #"\b"#,
        // A text style chosen in a ternary inside a font expression.
        #"\.font\(.*[?:]\s*\."# + textStyles + #"\b"#,
        #"\bFont\."# + textStyles + #"\b"#,
        #"systemFont\(ofSize:\s*[0-9]"#,
        #"\benum\s+\w*Layout\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func violatingLines(in source: String) -> [Int] {
        source.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let range = NSRange(line.startIndex..., in: line)
            let violates = forbiddenPatterns.contains { $0.firstMatch(in: line, range: range) != nil }
            return violates ? index + 1 : nil
        }
    }

    func testMenuViewsUseMenuMetricsForFontsAndLayout() throws {
        let menuViews = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/mergehawk/MenuViews.swift")
        let source = try String(contentsOf: menuViews, encoding: .utf8)
        let lines = Self.violatingLines(in: source)
        XCTAssertTrue(
            lines.isEmpty,
            "MenuViews.swift hardcodes a font size or layout enum on lines \(lines); use MenuMetrics tokens instead."
        )
    }

    func testMatcherFlagsHardcodedFontsAndLayoutEnums() {
        XCTAssertEqual(Self.violatingLines(in: ".font(.system(size: 12))"), [1])
        XCTAssertEqual(Self.violatingLines(in: ".font(.caption2.weight(.semibold))"), [1])
        XCTAssertEqual(Self.violatingLines(in: "enum FooLayout {"), [1])
        XCTAssertEqual(Self.violatingLines(in: "field.font = NSFont.systemFont(ofSize: 11)"), [1])
        XCTAssertEqual(Self.violatingLines(in: ".font(.system(.title2, design: .monospaced))"), [1])
        XCTAssertEqual(Self.violatingLines(in: "a\n.font(.headline)"), [2])
    }

    func testMatcherFlagsSystemFontSizesWithOrWithoutThePrefix() {
        XCTAssertEqual(Self.violatingLines(in: "field.font = .systemFont(ofSize: 12)"), [1])
        XCTAssertEqual(Self.violatingLines(in: "let font = systemFont(ofSize: 9, weight: .bold)"), [1])
        XCTAssertEqual(Self.violatingLines(in: "field.font = .systemFont(ofSize: size)"), [])
    }

    func testMatcherFlagsFontTextStyleReferences() {
        XCTAssertEqual(Self.violatingLines(in: "let font = Font.caption"), [1])
        XCTAssertEqual(Self.violatingLines(in: "var font: Font = Font.headline.weight(.bold)"), [1])
    }

    func testMatcherFlagsTextStylesInFontTernaries() {
        XCTAssertEqual(Self.violatingLines(in: ".font(isOpen ? .caption : metrics.type.cardTitle.font)"), [1])
        XCTAssertEqual(Self.violatingLines(in: ".font(isOpen ? metrics.type.cardTitle.font : .body)"), [1])
        XCTAssertEqual(Self.violatingLines(in: ".font(isOpen ? .subheadline.weight(.semibold) : metrics.type.cardTitle.font)"), [1])
    }

    func testMatcherAcceptsMetricsTokens() {
        XCTAssertEqual(Self.violatingLines(in: ".font(metrics.type.cardTitle.font)"), [])
        XCTAssertEqual(Self.violatingLines(in: "metrics.type.cardTitle"), [])
    }
}
