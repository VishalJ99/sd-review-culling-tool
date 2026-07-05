import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SDReviewCore

final class MediaScannerTests: XCTestCase {
    func testScannerIgnoresRawAndAppleDoubleButCountsRawAndHEIF() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let dcim = root.appendingPathComponent("DCIM/100_FUJI", isDirectory: true)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeJPEG(at: dcim.appendingPathComponent("DSCF0001.JPG"))
        FileManager.default.createFile(atPath: dcim.appendingPathComponent("DSCF0001.RAF").path, contents: Data([1, 2, 3]))
        FileManager.default.createFile(atPath: dcim.appendingPathComponent("DSCF0002.HEIF").path, contents: Data([1, 2, 3]))
        FileManager.default.createFile(atPath: dcim.appendingPathComponent("._DSCF0003.JPG").path, contents: Data([1, 2, 3]))

        let result = try MediaScanner().scan(source: root)

        XCTAssertEqual(result.items.map(\.relativePath), ["100_FUJI/DSCF0001.JPG"])
        XCTAssertEqual(result.rawFiles, ["100_FUJI/DSCF0001.RAF"])
        XCTAssertEqual(result.heifFiles, ["100_FUJI/DSCF0002.HEIF"])
    }

    private func makeJPEG(at url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Failed to create context")
            return
        }
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            XCTFail("Failed to create image destination")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
