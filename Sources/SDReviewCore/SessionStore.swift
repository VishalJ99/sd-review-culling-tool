import CryptoKit
import Foundation

public final class SessionStore {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = support.appendingPathComponent("SDReview/Sessions", isDirectory: true)
        }

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func sessionURL(sourceRoot: String, dateRange: DateRange?) -> URL {
        let key = "\(sourceRoot)|\(dateRange?.start.timeIntervalSince1970 ?? 0)|\(dateRange?.end.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    public func load(sourceRoot: String, dateRange: DateRange?) throws -> SessionDocument? {
        let url = sessionURL(sourceRoot: sourceRoot, dateRange: dateRange)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(SessionDocument.self, from: data)
    }

    public func save(_ document: SessionDocument, dateRange: DateRange?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = sessionURL(sourceRoot: document.sourceRoot, dateRange: dateRange)
        let temporaryURL = url.appendingPathExtension("tmp")
        let data = try encoder.encode(document)
        try data.write(to: temporaryURL, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: url)
    }

    public func reset(sourceRoot: String, dateRange: DateRange?) throws {
        let url = sessionURL(sourceRoot: sourceRoot, dateRange: dateRange)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
