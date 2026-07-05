import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SDReviewCore

final class MediaPreviewCacheTests: XCTestCase {
    func testScannerFingerprintAndPreviewCacheUseStableCardIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dcim = root.appendingPathComponent("DCIM/100_FUJI", isDirectory: true)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeJPEG(at: dcim.appendingPathComponent("DSCF0001.JPG"), width: 96, height: 64)

        let firstScan = try MediaScanner().scan(source: root)
        let secondScan = try MediaScanner().scan(source: root)
        let fingerprint = try XCTUnwrap(firstScan.cardFingerprint)

        XCTAssertFalse(fingerprint.isEmpty)
        XCTAssertEqual(firstScan.cardFingerprint, secondScan.cardFingerprint)

        let store = SessionStore(directory: root.appendingPathComponent("Sessions", isDirectory: true))
        let dateRange = DateRange(start: .distantPast, end: .distantFuture)
        XCTAssertNotEqual(
            store.sessionURL(sourceRoot: firstScan.sourceRoot, dateRange: dateRange, cardFingerprint: "card-a"),
            store.sessionURL(sourceRoot: firstScan.sourceRoot, dateRange: dateRange, cardFingerprint: "card-b")
        )

        let cache = MediaPreviewCache(cardFingerprint: fingerprint, maxBytes: 50 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: cache.rootURL) }

        let item = try XCTUnwrap(firstScan.items.first)
        let preview = try cache.ensureCachedImage(for: item, variant: .preview)
        let thumbnail = try cache.ensureCachedImage(for: item, variant: .thumbnail)

        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path))
        XCTAssertNotEqual(preview, item.fileURL)
        XCTAssertNotEqual(thumbnail, item.fileURL)
        XCTAssertLessThanOrEqual(try maxPixelDimension(of: thumbnail), 320)
    }

    private func makeJPEG(at url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Failed to create context")
            return
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            XCTFail("Failed to create image destination")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func maxPixelDimension(of url: URL) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(width, height)
    }
}
