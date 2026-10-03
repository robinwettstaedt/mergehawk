import AppKit

/// Compares two directories of PNG captures pixel for pixel. No tolerance, no masking.
struct VisualCaptureComparison {
    struct PixelBox: Equatable, CustomStringConvertible {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        var description: String { "x=\(x) y=\(y) w=\(width) h=\(height)" }
    }

    struct SizeMismatch: Equatable {
        let file: String
        let before: CGSize
        let after: CGSize
    }

    /// Everything that decides how decoded pixel bytes are laid out and interpreted, apart from the pixel size.
    struct PixelFormat: Equatable, CustomStringConvertible {
        let bitsPerSample: Int
        let samplesPerPixel: Int
        let bitsPerPixel: Int
        let bitmapFormat: UInt
        let colorSpaceName: String
        let colorSpace: String
        let colorProfile: Data?

        var description: String {
            "\(bitsPerSample)-bit x\(samplesPerPixel) (\(bitsPerPixel) bpp), format \(bitmapFormat), \(colorSpace)"
        }
    }

    struct FormatMismatch: Equatable {
        let file: String
        let before: PixelFormat
        let after: PixelFormat
    }

    struct PixelDifference: Equatable {
        let file: String
        /// Top-left origin, in pixels.
        let boundingBox: PixelBox
        let count: Int
    }

    struct Report: CustomStringConvertible {
        var comparedFiles: [String] = []
        var missingFromAfter: [String] = []
        var onlyInAfter: [String] = []
        var sizeMismatches: [SizeMismatch] = []
        var formatMismatches: [FormatMismatch] = []
        var pixelDifferences: [PixelDifference] = []

        var beforeIsEmpty: Bool { comparedFiles.isEmpty && missingFromAfter.isEmpty }

        /// Files only in "after" are reported for separate review but do not fail the comparison.
        var failed: Bool {
            beforeIsEmpty || !missingFromAfter.isEmpty || !sizeMismatches.isEmpty || !formatMismatches.isEmpty
                || !pixelDifferences.isEmpty
        }

        var description: String {
            var lines = ["Compared \(comparedFiles.count) capture(s)."]
            if beforeIsEmpty {
                lines.append("FAIL: \"before\" contains no PNG captures.")
            }
            lines += missingFromAfter.map { "FAIL missing from after: \($0)" }
            lines += sizeMismatches.map {
                "FAIL size mismatch: \($0.file) before \(Int($0.before.width))x\(Int($0.before.height))"
                    + " after \(Int($0.after.width))x\(Int($0.after.height))"
            }
            lines += formatMismatches.map {
                "FAIL format mismatch: \($0.file) before \($0.before) after \($0.after)"
            }
            lines += pixelDifferences.map {
                "FAIL pixels differ: \($0.file) box \($0.boundingBox) count \($0.count)"
            }
            lines += onlyInAfter.map { "Only in after (review separately): \($0)" }
            lines.append(failed ? "Result: FAIL" : "Result: PASS")
            return lines.joined(separator: "\n")
        }
    }

    enum ComparisonError: LocalizedError {
        case undecodable(URL)
        case unsupportedLayout(URL)

        var errorDescription: String? {
            switch self {
            case let .undecodable(url): "Could not decode PNG at \(url.path)"
            case let .unsupportedLayout(url): "Only interleaved, whole-byte pixels are supported: \(url.path)"
            }
        }
    }

    static func compare(before: URL, after: URL) throws -> Report {
        let beforeFiles = try pngNames(in: before)
        let afterFiles = try pngNames(in: after)
        var report = Report()
        report.onlyInAfter = afterFiles.subtracting(beforeFiles).sorted()
        for file in beforeFiles.sorted() {
            guard afterFiles.contains(file) else {
                report.missingFromAfter.append(file)
                continue
            }
            report.comparedFiles.append(file)
            let beforeImage = try DecodedImage(url: before.appendingPathComponent(file))
            let afterImage = try DecodedImage(url: after.appendingPathComponent(file))
            guard beforeImage.width == afterImage.width, beforeImage.height == afterImage.height else {
                report.sizeMismatches.append(SizeMismatch(
                    file: file,
                    before: CGSize(width: beforeImage.width, height: beforeImage.height),
                    after: CGSize(width: afterImage.width, height: afterImage.height)
                ))
                continue
            }
            guard beforeImage.format == afterImage.format else {
                report.formatMismatches.append(FormatMismatch(
                    file: file,
                    before: beforeImage.format,
                    after: afterImage.format
                ))
                continue
            }
            if let difference = difference(file: file, beforeImage, afterImage) {
                report.pixelDifferences.append(difference)
            }
        }
        return report
    }

    private static func pngNames(in directory: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.lowercased().hasSuffix(".png") })
    }

    /// Compares the decoded bytes directly; both images have the same size and pixel format.
    private static func difference(file: String, _ before: DecodedImage, _ after: DecodedImage) -> PixelDifference? {
        let bytesPerPixel = before.format.bitsPerPixel / 8
        let rowLength = before.width * bytesPerPixel
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, count = 0
        for y in 0..<before.height {
            let beforeRow = before.bytes + y * before.bytesPerRow
            let afterRow = after.bytes + y * after.bytesPerRow
            guard memcmp(beforeRow, afterRow, rowLength) != 0 else { continue }
            for x in 0..<before.width
            where memcmp(beforeRow + x * bytesPerPixel, afterRow + x * bytesPerPixel, bytesPerPixel) != 0 {
                count += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard count > 0 else { return nil }
        return PixelDifference(
            file: file,
            boundingBox: PixelBox(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
            count: count
        )
    }
}

/// A PNG decoded by `NSBitmapImageRep`, compared as-is without redrawing or color conversion.
/// Rows run top to bottom.
private struct DecodedImage {
    let representation: NSBitmapImageRep
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let format: VisualCaptureComparison.PixelFormat

    var bytes: UnsafeMutablePointer<UInt8> { representation.bitmapData! }

    init(url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let representation = NSBitmapImageRep(data: data),
              representation.bitmapData != nil
        else {
            throw VisualCaptureComparison.ComparisonError.undecodable(url)
        }
        guard !representation.isPlanar, representation.bitsPerPixel % 8 == 0 else {
            throw VisualCaptureComparison.ComparisonError.unsupportedLayout(url)
        }
        self.representation = representation
        width = representation.pixelsWide
        height = representation.pixelsHigh
        bytesPerRow = representation.bytesPerRow
        format = VisualCaptureComparison.PixelFormat(
            bitsPerSample: representation.bitsPerSample,
            samplesPerPixel: representation.samplesPerPixel,
            bitsPerPixel: representation.bitsPerPixel,
            bitmapFormat: representation.bitmapFormat.rawValue,
            colorSpaceName: representation.colorSpaceName.rawValue,
            colorSpace: representation.colorSpace.localizedName ?? representation.colorSpaceName.rawValue,
            colorProfile: representation.colorSpace.iccProfileData
        )
    }
}
