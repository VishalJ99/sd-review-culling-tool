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

    public func sessionURL(sourceRoot: String, dateRange: DateRange?, cardFingerprint: String? = nil) -> URL {
        let identity = cardFingerprint ?? sourceRoot
        let key = "\(identity)|\(dateRange?.start.timeIntervalSince1970 ?? 0)|\(dateRange?.end.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }

    public func load(sourceRoot: String, dateRange: DateRange?, cardFingerprint: String? = nil) throws -> SessionDocument? {
        let url = sessionURL(sourceRoot: sourceRoot, dateRange: dateRange, cardFingerprint: cardFingerprint)
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return try decoder.decode(SessionDocument.self, from: data)
        }
        guard cardFingerprint != nil else { return nil }
        return try fallbackLoad(sourceRoot: sourceRoot, dateRange: dateRange)
    }

    public func save(_ document: SessionDocument, dateRange: DateRange?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = sessionURL(sourceRoot: document.sourceRoot, dateRange: dateRange, cardFingerprint: document.cardFingerprint)
        let data = try encoder.encode(document)
        try data.write(to: url, options: [.atomic])
    }

    public func reset(sourceRoot: String, dateRange: DateRange?, cardFingerprint: String? = nil) throws {
        let url = sessionURL(sourceRoot: sourceRoot, dateRange: dateRange, cardFingerprint: cardFingerprint)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try removeFallbackSessions(sourceRoot: sourceRoot, dateRange: dateRange)
    }

    private func fallbackLoad(sourceRoot: String, dateRange: DateRange?) throws -> SessionDocument? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (url: URL, date: Date, document: SessionDocument)? in
                guard let data = try? Data(contentsOf: url),
                      let document = try? decoder.decode(SessionDocument.self, from: data),
                      document.sourceRoot == sourceRoot,
                      document.dateRange == dateRange else {
                    return nil
                }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return (url, values?.contentModificationDate ?? .distantPast, document)
            }
            .sorted { $0.date > $1.date }
        return candidates.first?.document
    }

    private func removeFallbackSessions(sourceRoot: String, dateRange: DateRange?) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let document = try? decoder.decode(SessionDocument.self, from: data),
                  document.sourceRoot == sourceRoot,
                  document.dateRange == dateRange else {
                continue
            }
            try FileManager.default.removeItem(at: url)
        }
    }
}
