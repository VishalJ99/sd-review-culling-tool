import XCTest
@testable import SDReviewCore

final class ReviewSessionTests: XCTestCase {
    func testKeepOnUndecidedAutoAdvancesAndToggleDoesNot() {
        let now = Date()
        let document = SessionDocument(
            sourceRoot: "/tmp/card/DCIM",
            items: [
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0001.JPG", filename: "DSCF0001.JPG", kind: .photo, captureDate: now, fileSize: 1),
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0002.JPG", filename: "DSCF0002.JPG", kind: .photo, captureDate: now.addingTimeInterval(1), fileSize: 1)
            ]
        )
        let session = ReviewSession(document: document)

        XCTAssertEqual(session.currentItem?.filename, "DSCF0001.JPG")
        session.markKeepOrToggle()

        XCTAssertEqual(session.document.items[0].decision, .keep)
        XCTAssertEqual(session.currentItem?.filename, "DSCF0002.JPG")

        session.movePrevious()
        session.markKeepOrToggle()

        XCTAssertEqual(session.document.items[0].decision, .undecided)
        XCTAssertEqual(session.currentItem?.filename, "DSCF0001.JPG")
    }

    func testRejectFilterAndUndo() {
        let now = Date()
        let document = SessionDocument(
            sourceRoot: "/tmp/card/DCIM",
            items: [
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0001.JPG", filename: "DSCF0001.JPG", kind: .photo, captureDate: now, fileSize: 1),
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0002.JPG", filename: "DSCF0002.JPG", kind: .photo, captureDate: now.addingTimeInterval(1), fileSize: 1)
            ]
        )
        let session = ReviewSession(document: document)

        session.markRejectOrToggle()
        session.filter = .rejects

        XCTAssertEqual(session.filteredItems.map(\.filename), ["DSCF0001.JPG"])

        session.undo()

        XCTAssertEqual(session.document.items.map(\.decision), [.undecided, .undecided])
    }

    func testUndoAfterTwoRejectsRestoresOnlyMostRecentReject() {
        let now = Date()
        let document = SessionDocument(
            sourceRoot: "/tmp/card/DCIM",
            items: [
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0001.JPG", filename: "DSCF0001.JPG", kind: .photo, captureDate: now, fileSize: 1),
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0002.JPG", filename: "DSCF0002.JPG", kind: .photo, captureDate: now.addingTimeInterval(1), fileSize: 1),
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0003.MOV", filename: "DSCF0003.MOV", kind: .video, captureDate: now.addingTimeInterval(2), fileSize: 1)
            ]
        )
        let session = ReviewSession(document: document)

        session.markRejectOrToggle()
        session.markRejectOrToggle()
        session.undo()

        XCTAssertEqual(session.document.items.map(\.decision), [.reject, .undecided, .undecided])
        XCTAssertEqual(session.currentItem?.filename, "DSCF0002.JPG")
    }

    func testSegmentImpliesKeep() {
        let document = SessionDocument(
            sourceRoot: "/tmp/card/DCIM",
            items: [
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0001.MOV", filename: "DSCF0001.MOV", kind: .video, captureDate: Date(), fileSize: 1)
            ]
        )
        let session = ReviewSession(document: document)

        session.addSegment(start: 4, end: 1)

        XCTAssertEqual(session.document.items[0].decision, .keep)
        XCTAssertEqual(session.document.items[0].segments[0].startSeconds, 1)
        XCTAssertEqual(session.document.items[0].segments[0].endSeconds, 4)
    }

    func testSegmentsDoNotApplyToPhotos() {
        let document = SessionDocument(
            sourceRoot: "/tmp/card/DCIM",
            items: [
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0001.JPG", filename: "DSCF0001.JPG", kind: .photo, captureDate: Date(), fileSize: 1)
            ]
        )
        let session = ReviewSession(document: document)

        session.addSegment(start: 1, end: 2)

        XCTAssertEqual(session.document.items[0].decision, .undecided)
        XCTAssertTrue(session.document.items[0].segments.isEmpty)
    }

    func testAutoAdvanceInUndecidedFilterDoesNotSkipNextRemainingItem() {
        let now = Date()
        let document = SessionDocument(
            sourceRoot: "/tmp/card/DCIM",
            filter: .undecided,
            items: [
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0001.JPG", filename: "DSCF0001.JPG", kind: .photo, captureDate: now, fileSize: 1),
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0002.JPG", filename: "DSCF0002.JPG", kind: .photo, captureDate: now.addingTimeInterval(1), fileSize: 1),
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0003.JPG", filename: "DSCF0003.JPG", kind: .photo, captureDate: now.addingTimeInterval(2), fileSize: 1)
            ]
        )
        let session = ReviewSession(document: document)

        session.markKeepOrToggle()

        XCTAssertEqual(session.filteredItems.map(\.filename), ["DSCF0002.JPG", "DSCF0003.JPG"])
        XCTAssertEqual(session.currentItem?.filename, "DSCF0002.JPG")
    }

    func testUndoStackPersistsThroughSessionStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = SessionDocument(
            sourceRoot: "/tmp/card/DCIM",
            items: [
                MediaItem(sourceRoot: "/tmp/card/DCIM", relativePath: "100_FUJI/DSCF0001.JPG", filename: "DSCF0001.JPG", kind: .photo, captureDate: Date(), fileSize: 1)
            ]
        )
        let session = ReviewSession(document: document)
        session.markKeepOrToggle()

        let store = SessionStore(directory: directory)
        try store.save(session.document, dateRange: nil)
        let loaded = try XCTUnwrap(store.load(sourceRoot: "/tmp/card/DCIM", dateRange: nil))
        let restored = ReviewSession(document: loaded)

        restored.undo()

        XCTAssertEqual(restored.document.items[0].decision, .undecided)
    }

    func testSessionStoreFallsBackWhenCardFingerprintChangesAndResetClearsMatches() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceRoot = "/tmp/card/DCIM"
        let range = DateRange(start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20))
        let document = SessionDocument(
            sourceRoot: sourceRoot,
            cardFingerprint: "old-fingerprint",
            dateRange: range,
            items: [
                MediaItem(sourceRoot: sourceRoot, relativePath: "100_FUJI/DSCF0001.JPG", filename: "DSCF0001.JPG", kind: .photo, captureDate: Date(), fileSize: 1, decision: .keep)
            ]
        )
        let store = SessionStore(directory: directory)
        try store.save(document, dateRange: range)

        let loaded = try XCTUnwrap(store.load(sourceRoot: sourceRoot, dateRange: range, cardFingerprint: "new-fingerprint"))
        XCTAssertEqual(loaded.items.first?.decision, .keep)

        try store.reset(sourceRoot: sourceRoot, dateRange: range, cardFingerprint: "new-fingerprint")
        XCTAssertNil(try store.load(sourceRoot: sourceRoot, dateRange: range, cardFingerprint: "old-fingerprint"))
    }
}
