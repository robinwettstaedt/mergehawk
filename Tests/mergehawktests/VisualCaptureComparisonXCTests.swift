@testable import mergehawk
import AppKit
import XCTest

final class VisualCaptureComparisonXCTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("visual-capture-comparison-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Compares `MERGEHAWK_UI_COMPARE_BEFORE` with `MERGEHAWK_UI_COMPARE_AFTER`.
    func testCaptureDirectoriesMatch() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let beforePath = environment["MERGEHAWK_UI_COMPARE_BEFORE"], !beforePath.isEmpty,
              let afterPath = environment["MERGEHAWK_UI_COMPARE_AFTER"], !afterPath.isEmpty
        else {
            throw XCTSkip("Set MERGEHAWK_UI_COMPARE_BEFORE and MERGEHAWK_UI_COMPARE_AFTER to compare captures.")
        }
        let report = try VisualCaptureComparison.compare(
            before: URL(fileURLWithPath: beforePath),
            after: URL(fileURLWithPath: afterPath)
        )
        print(report)
        XCTAssertFalse(report.failed, report.description)
    }

    func testIdenticalDirectoriesCompareEqual() throws {
        let (before, after) = try makeDirectories()
        try writeImage(width: 4, height: 3, to: before.appendingPathComponent("a.png"))
        try writeImage(width: 4, height: 3, to: after.appendingPathComponent("a.png"))

        let report = try VisualCaptureComparison.compare(before: before, after: after)
        XCTAssertEqual(report.comparedFiles, ["a.png"])
        XCTAssertTrue(report.pixelDifferences.isEmpty)
        XCTAssertFalse(report.failed)
    }

    func testOneChangedPixelIsReportedWithItsBoundingBoxAndCount() throws {
        let (before, after) = try makeDirectories()
        try writeImage(width: 4, height: 3, to: before.appendingPathComponent("a.png"))
        try writeImage(width: 4, height: 3, changedPixels: [(2, 1)], to: after.appendingPathComponent("a.png"))

        let report = try VisualCaptureComparison.compare(before: before, after: after)
        XCTAssertEqual(report.pixelDifferences, [
            VisualCaptureComparison.PixelDifference(
                file: "a.png",
                boundingBox: .init(x: 2, y: 1, width: 1, height: 1),
                count: 1
            )
        ])
        XCTAssertTrue(report.failed)
    }

    func testChangesInSeparatePlacesProduceOneBoundingBoxCoveringBoth() throws {
        let (before, after) = try makeDirectories()
        try writeImage(width: 10, height: 8, to: before.appendingPathComponent("a.png"))
        try writeImage(width: 10, height: 8, changedPixels: [(1, 2), (7, 6)], to: after.appendingPathComponent("a.png"))

        let report = try VisualCaptureComparison.compare(before: before, after: after)
        XCTAssertEqual(report.pixelDifferences.map(\.boundingBox), [.init(x: 1, y: 2, width: 7, height: 5)])
        XCTAssertEqual(report.pixelDifferences.map(\.count), [2])
    }

    func testMissingAfterFileFailsAndExtraAfterFileIsOnlyReported() throws {
        let (before, after) = try makeDirectories()
        try writeImage(width: 4, height: 3, to: before.appendingPathComponent("a.png"))
        try writeImage(width: 4, height: 3, to: after.appendingPathComponent("a.png"))
        try writeImage(width: 4, height: 3, to: after.appendingPathComponent("new.png"))

        let extraOnly = try VisualCaptureComparison.compare(before: before, after: after)
        XCTAssertEqual(extraOnly.onlyInAfter, ["new.png"])
        XCTAssertFalse(extraOnly.failed)

        try writeImage(width: 4, height: 3, to: before.appendingPathComponent("gone.png"))
        let missing = try VisualCaptureComparison.compare(before: before, after: after)
        XCTAssertEqual(missing.missingFromAfter, ["gone.png"])
        XCTAssertTrue(missing.failed)
    }

    func testDifferentPixelSizesAreReportedAsSizeMismatch() throws {
        let (before, after) = try makeDirectories()
        try writeImage(width: 4, height: 3, to: before.appendingPathComponent("a.png"))
        try writeImage(width: 4, height: 5, to: after.appendingPathComponent("a.png"))

        let report = try VisualCaptureComparison.compare(before: before, after: after)
        XCTAssertEqual(report.sizeMismatches, [
            VisualCaptureComparison.SizeMismatch(
                file: "a.png",
                before: CGSize(width: 4, height: 3),
                after: CGSize(width: 4, height: 5)
            )
        ])
        XCTAssertTrue(report.pixelDifferences.isEmpty)
        XCTAssertTrue(report.failed)
    }

    func testDifferentPixelFormatsAreReportedAsFormatMismatch() throws {
        let (before, after) = try makeDirectories()
        try writeImage(width: 4, height: 3, to: before.appendingPathComponent("a.png"))
        try writeImage(width: 4, height: 3, hasAlpha: false, to: after.appendingPathComponent("a.png"))

        let report = try VisualCaptureComparison.compare(before: before, after: after)
        XCTAssertEqual(report.formatMismatches.map(\.file), ["a.png"])
        XCTAssertEqual(report.formatMismatches.map(\.before.samplesPerPixel), [4])
        XCTAssertEqual(report.formatMismatches.map(\.after.samplesPerPixel), [3])
        XCTAssertTrue(report.pixelDifferences.isEmpty)
        XCTAssertTrue(report.failed)
    }

    func testEmptyBeforeDirectoryFails() throws {
        let (before, after) = try makeDirectories()
        try writeImage(width: 4, height: 3, to: after.appendingPathComponent("a.png"))

        let report = try VisualCaptureComparison.compare(before: before, after: after)
        XCTAssertTrue(report.failed)
    }

    private func makeDirectories() throws -> (URL, URL) {
        let before = directory.appendingPathComponent("before")
        let after = directory.appendingPathComponent("after")
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: after, withIntermediateDirectories: true)
        return (before, after)
    }

    /// A gray image; `changedPixels` (x, y from the top-left) are red.
    private func writeImage(
        width: Int,
        height: Int,
        hasAlpha: Bool = true,
        changedPixels: [(Int, Int)] = [],
        to url: URL
    ) throws {
        let samplesPerPixel = hasAlpha ? 4 : 3
        let representation = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: samplesPerPixel,
            hasAlpha: hasAlpha,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * samplesPerPixel,
            bitsPerPixel: 8 * samplesPerPixel
        ))
        let gray = NSColor(deviceRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        for y in 0..<height {
            for x in 0..<width {
                let isChanged = changedPixels.contains { $0 == (x, y) }
                representation.setColor(isChanged ? red : gray, atX: x, y: y)
            }
        }
        try XCTUnwrap(representation.representation(using: .png, properties: [:])).write(to: url)
    }
}
