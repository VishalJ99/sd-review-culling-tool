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
        XCTAssertGreaterThan(result.rawFiles.count, 0)

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

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
        XCTAssertGreaterThan(report.manifest.items.flatMap(\.outputFilenames).count, 0)
        XCTAssertTrue(report.manifest.failures.isEmpty, report.manifest.failures.joined(separator: "\n"))
    }
}
