import XCTest
@testable import SDReviewCore

final class ExporterTests: XCTestCase {
    actor ProgressRecorder {
        private var values: [ExportProgress] = []

        func append(_ value: ExportProgress) {
            values.append(value)
        }

        func snapshot() -> [ExportProgress] {
            values
        }
    }

    func testManifestIncludesRejectsAndUndecidedItems() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("DCIM", isDirectory: true)
        let folder = source.appendingPathComponent("100_FUJI", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keepURL = folder.appendingPathComponent("DSCF0001.JPG")
        let rejectURL = folder.appendingPathComponent("DSCF0002.JPG")
        let undecidedURL = folder.appendingPathComponent("DSCF0003.JPG")
        try Data("keep".utf8).write(to: keepURL)
        try Data("reject".utf8).write(to: rejectURL)
        try Data("undecided".utf8).write(to: undecidedURL)

        let now = Date()
        let document = SessionDocument(
            sourceRoot: source.path,
            items: [
                MediaItem(sourceRoot: source.path, relativePath: "100_FUJI/DSCF0001.JPG", filename: "DSCF0001.JPG", kind: .photo, captureDate: now, fileSize: 4, decision: .keep),
                MediaItem(sourceRoot: source.path, relativePath: "100_FUJI/DSCF0002.JPG", filename: "DSCF0002.JPG", kind: .photo, captureDate: now, fileSize: 6, decision: .reject),
                MediaItem(sourceRoot: source.path, relativePath: "100_FUJI/DSCF0003.JPG", filename: "DSCF0003.JPG", kind: .photo, captureDate: now, fileSize: 9, decision: .undecided)
            ]
        )

        let exportURL = root.appendingPathComponent("export", isDirectory: true)
        let report = try await MediaExporter().export(document: document, options: ExportOptions(destination: exportURL))

        XCTAssertEqual(report.manifest.items.count, 3)
        XCTAssertEqual(report.manifest.items.map(\.decision), [.keep, .reject, .undecided])
        XCTAssertEqual(report.manifest.items[0].outputFilenames.count, 1)
        XCTAssertEqual(report.manifest.items[0].outputFiles?.count, 1)
        XCTAssertTrue(report.manifest.items[1].outputFilenames.isEmpty)
        XCTAssertTrue(report.manifest.items[2].outputFilenames.isEmpty)
    }

    func testExporterBlocksDestinationInsideSourceTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("DCIM", isDirectory: true)
        let folder = source.appendingPathComponent("100_FUJI", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = folder.appendingPathComponent("DSCF0001.JPG")
        try Data("keep".utf8).write(to: url)
        let document = SessionDocument(
            sourceRoot: source.path,
            items: [
                MediaItem(sourceRoot: source.path, relativePath: "100_FUJI/DSCF0001.JPG", filename: "DSCF0001.JPG", kind: .photo, captureDate: Date(), fileSize: 4, decision: .keep)
            ]
        )

        do {
            _ = try await MediaExporter().export(
                document: document,
                options: ExportOptions(destination: source.appendingPathComponent("Export"))
            )
            XCTFail("Expected unsafe destination failure")
        } catch ExportError.unsafeDestination {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExporterReportsProgressAndCollectsPerFileFailures() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("DCIM", isDirectory: true)
        let folder = source.appendingPathComponent("100_FUJI", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existingURL = folder.appendingPathComponent("DSCF0001.JPG")
        try Data("keep".utf8).write(to: existingURL)

        let now = Date()
        let document = SessionDocument(
            sourceRoot: source.path,
            items: [
                MediaItem(sourceRoot: source.path, relativePath: "100_FUJI/DSCF0001.JPG", filename: "DSCF0001.JPG", kind: .photo, captureDate: now, fileSize: 4, decision: .keep),
                MediaItem(sourceRoot: source.path, relativePath: "100_FUJI/MISSING.JPG", filename: "MISSING.JPG", kind: .photo, captureDate: now, fileSize: 4, decision: .keep)
            ]
        )
        let recorder = ProgressRecorder()

        let report = try await MediaExporter().export(
            document: document,
            options: ExportOptions(destination: root.appendingPathComponent("export", isDirectory: true))
        ) { progress in
            await recorder.append(progress)
        }

        let progress = await recorder.snapshot()
        XCTAssertEqual(progress.first?.completedItems, 0)
        XCTAssertEqual(progress.last?.completedItems, 2)
        XCTAssertEqual(progress.last?.totalItems, 2)
        XCTAssertEqual(report.manifest.failures.count, 1)
        XCTAssertEqual(report.manifest.items[0].outputFilenames.count, 1)
        XCTAssertEqual(report.manifest.items[0].outputFiles?.count, 1)
        XCTAssertTrue(report.manifest.items[1].outputFilenames.isEmpty)
        XCTAssertNotNil(report.manifest.items[1].failure)
    }

    func testExporterReplacesSameSizeCorruptCopyOutputs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("DCIM", isDirectory: true)
        let folder = source.appendingPathComponent("100_FUJI", isDirectory: true)
        let export = root.appendingPathComponent("export/photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceURL = folder.appendingPathComponent("DSCF0001.JPG")
        try Data("good".utf8).write(to: sourceURL)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let staleName = "\(formatter.string(from: captureDate))_DSCF0001.jpg"
        try Data("evil".utf8).write(to: export.appendingPathComponent(staleName))
        let document = SessionDocument(
            sourceRoot: source.path,
            items: [
                MediaItem(sourceRoot: source.path, relativePath: "100_FUJI/DSCF0001.JPG", filename: "DSCF0001.JPG", kind: .photo, captureDate: captureDate, fileSize: 4, decision: .keep)
            ]
        )

        let report = try await MediaExporter().export(
            document: document,
            options: ExportOptions(destination: root.appendingPathComponent("export", isDirectory: true))
        )

        let outputName = try XCTUnwrap(report.manifest.items.first?.outputFilenames.first)
        let outputURL = export.appendingPathComponent(outputName)
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("good".utf8))
    }
}
