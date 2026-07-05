import CryptoKit
import Foundation

public enum CardFingerprint {
    public static func make(sourceRoot: URL, mediaFileURLs: [URL]) -> String {
        let root = sourceRoot.standardizedFileURL
        let volumeUUID = (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? "unknown-volume"
        var totalBytes: Int64 = 0
        var latestMTime: TimeInterval = 0
        var folderNames: Set<String> = []

        for url in mediaFileURLs {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            totalBytes += Int64(values?.fileSize ?? 0)
            latestMTime = max(latestMTime, values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            folderNames.insert(url.deletingLastPathComponent().lastPathComponent)
        }

        let folders = folderNames.sorted().joined(separator: ",")
        let payload = [
            "volume=\(volumeUUID)",
            "root=\(root.path)",
            "folders=\(folders)",
            "count=\(mediaFileURLs.count)",
            "bytes=\(totalBytes)",
            "latest=\(Int(latestMTime))"
        ].joined(separator: "|")
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
