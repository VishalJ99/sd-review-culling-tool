import Foundation
import SDReviewCore

struct ActionLogger {
    let url: URL

    init(baseDirectory: URL? = nil) {
        let root = baseDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("SDReview", isDirectory: true)
        url = root
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("actions.jsonl")
    }

    func ensureExists() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        } catch {
            // Action logging must never interfere with review.
        }
    }

    func record(_ event: String, item: MediaItem?, details: [String: String] = [:]) {
        var payload: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "details": details
        ]
        if let item {
            payload["item"] = [
                "relativePath": item.relativePath,
                "filename": item.filename,
                "kind": item.kind.rawValue,
                "decision": item.decision.rawValue,
                "segments": item.segments.count
            ]
        }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try handle.seekToEnd()
            handle.write(data)
            handle.write(Data([0x0A]))
        } catch {
            // Action logging must never interfere with review.
        }
    }
}
