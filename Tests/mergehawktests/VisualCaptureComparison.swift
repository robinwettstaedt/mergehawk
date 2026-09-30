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
        var pixelDifferences: [PixelDifference] = []

        var beforeIsEmpty: Bool { comparedFiles.isEmpty && missingFromAfter.isEmpty }

        /// Files only in "after" are reported for separate review but do not fail the comparison.
        var failed: Bool {
            beforeIsEmpty || !missingFromAfter.isEmpty || !sizeMismatches.isEmpty || !pixelDifferences.isEmpty
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

        var errorDescription: String? {
            switch self {
            case let .undecodable(url): "Could not decode PNG at \(url.path)"
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
            let beforeImage = try RGBAImage(url: before.appendingPathComponent(file))
            let afterImage = try RGBAImage(url: after.appendingPathComponent(file))
            guard beforeImage.width == afterImage.width, beforeImage.height == afterImage.height else {
                report.sizeMismatches.append(SizeMismatch(
                    file: file,
                    before: CGSize(width: beforeImage.width, height: beforeImage.height),
                    after: CGSize(width: afterImage.width, height: afterImage.height)
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

    private static func difference(file: String, _ before: RGBAImage, _ after: RGBAImage) -> PixelDifference? {
        guard before.pixels != after.pixels else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, count = 0
        before.pixels.withUnsafeBytes { beforeBytes in
            after.pixels.withUnsafeBytes { afterBytes in
                let beforePixels = beforeBytes.bindMemory(to: UInt32.self)
                let afterPixels = afterBytes.bindMemory(to: UInt32.self)
                for y in 0..<before.height {
                    for x in 0..<before.width where beforePixels[y * before.width + x] != afterPixels[y * before.width + x] {
                        count += 1
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                    }
                }
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

/// A decoded image as RGBA8 pixels in sRGB, rows top to bottom, at the image's pixel size.
private struct RGBAImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let representation = NSBitmapImageRep(data: data),
              let image = representation.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            throw VisualCaptureComparison.ComparisonError.undecodable(url)
        }
        let width = representation.pixelsWide
        let height = representation.pixelsHigh
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            throw VisualCaptureComparison.ComparisonError.undecodable(url)
        }
        self.width = width
        self.height = height
        pixels = buffer
    }
}
