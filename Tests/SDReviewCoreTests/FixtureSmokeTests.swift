import XCTest
@testable import SDReviewCore

final class FixtureSmokeTests: XCTestCase {
    func testCopiedFixtureScansAndExportsSmallSubsetWhenProvided() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["SDREVIEW_FIXTURE"], !fixture.isEmpty else {
            throw XCTSkip("Set SDREVIEW_FIXTURE to run copied SD-card smoke test.")
        }

        let fixtureURL = URL(fileURLWithPath: fixture)
        let result = try MediaScanner().scan(source: fixtureURL)

        XCTAssertGreaterThan(result.items.count, 0)
        XCTAssertTrue(result.items.allSatisfy { !$0.filename.hasPrefix("._") })
        XCTAssertEqual(result.items, result.items.sorted {
            if $0.captureDate != $1.captureDate {
                return $0.captureDate < $1.captureDate
            }
            return $0.relativePath < $1.relativePath
        })
        let fingerprint = try XCTUnwrap(result.cardFingerprint)
        XCTAssertFalse(fingerprint.isEmpty)
        XCTAssertGreaterThan(result.rawFiles.count, 0)
        try verifyPreviewCache(result: result, fingerprint: fingerprint)

        var keepers: [MediaItem] = []
        if var photo = result.items.first(where: { $0.kind == .photo }) {
            photo.decision = .keep
            keepers.append(photo)
        }
        if var video = result.items.first(where: { $0.kind == .video }) {
            video.decision = .keep
            video.segments = [VideoSegment(startSeconds: 0, endSeconds: 1)]
            keepers.append(video)
        }
        XCTAssertFalse(keepers.isEmpty)

        let document = SessionDocument(
            sourceRoot: result.sourceRoot,
            items: keepers,
            rawFiles: result.rawFiles,
            heifFiles: result.heifFiles,
            problems: result.problems
        )
        let destination = fixtureURL
            .deletingLastPathComponent()
            .appendingPathComponent("smoke-export-core", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let report = try await MediaExporter().export(
            document: document,
            options: ExportOptions(destination: destination, flatMediaFolder: false)
        )
        try """
        SD Review smoke export

        Recreate:
        SDREVIEW_FIXTURE=\"\(fixture)\" swift test --filter FixtureSmokeTests

        Expected result:
        - manifest.json exists
        - manifest failures array is empty
        - at least one copied real camera output exists
        """.write(to: destination.appendingPathComponent("reproduction.txt"), atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("reproduction.txt").path))
        XCTAssertGreaterThan(report.manifest.items.flatMap(\.outputFilenames).count, 0)
        XCTAssertTrue(report.manifest.failures.isEmpty, report.manifest.failures.joined(separator: "\n"))
    }

    private func verifyPreviewCache(result: ScanResult, fingerprint: String) throws {
        let cache = MediaPreviewCache(cardFingerprint: fingerprint, maxBytes: 100 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: cache.rootURL) }

        if let photo = result.items.first(where: { $0.kind == .photo }) {
            let preview = try cache.ensureCachedImage(for: photo, variant: .preview)
            let thumbnail = try cache.ensureCachedImage(for: photo, variant: .thumbnail)
            XCTAssertTrue(FileManager.default.fileExists(atPath: preview.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path))
        }

        if let video = result.items.first(where: { $0.kind == .video }) {
            let poster = try cache.ensureCachedImage(for: video, variant: .thumbnail)
            XCTAssertTrue(FileManager.default.fileExists(atPath: poster.path))
        }
    }
}
