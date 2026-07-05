import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CacheVariant: String, Sendable {
    case preview
    case thumbnail
}

public enum MediaPreviewCacheError: Error, LocalizedError {
    case cannotCreateImage(URL)
    case cannotCreateDestination(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateImage(let url): "Cannot create cached image for \(url.lastPathComponent)."
        case .cannotCreateDestination(let url): "Cannot write cached image to \(url.path)."
        }
    }
}

public final class MediaPreviewCache {
    public let rootURL: URL
    public let maxBytes: Int64

    public init(cardFingerprint: String, maxBytes: Int64 = 5 * 1024 * 1024 * 1024) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        rootURL = caches.appendingPathComponent("SDReview", isDirectory: true)
            .appendingPathComponent(cardFingerprint, isDirectory: true)
        self.maxBytes = maxBytes
    }

    public func cachedURL(for item: MediaItem, variant: CacheVariant) -> URL {
        rootURL
            .appendingPathComponent(variant.rawValue, isDirectory: true)
            .appendingPathComponent(cacheKey(for: item) + ".jpg")
    }

    public func existingURL(for item: MediaItem, variant: CacheVariant) -> URL? {
        let url = cachedURL(for: item, variant: variant)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func ensureCachedImage(for item: MediaItem, variant: CacheVariant) throws -> URL {
        let target = cachedURL(for: item, variant: variant)
        if FileManager.default.fileExists(atPath: target.path) {
            if isReadableJPEG(target) {
                touch(target)
                return target
            }
            try? FileManager.default.removeItem(at: target)
        }

        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch item.kind {
        case .photo:
            try writePhotoPreview(source: item.fileURL, destination: target, maxPixelSize: variant == .preview ? 2560 : 320)
        case .video:
            try writeVideoPoster(source: item.fileURL, destination: target, maxPixelSize: 320)
        }
        try evictIfNeeded()
        return target
    }

    public func warm(items: [MediaItem], currentID: String?) {
        let prioritized = priorityItems(items: items, currentID: currentID)
        for item in prioritized {
            if item.kind == .photo {
                _ = try? ensureCachedImage(for: item, variant: .preview)
            }
            _ = try? ensureCachedImage(for: item, variant: .thumbnail)
        }
    }

    private func priorityItems(items: [MediaItem], currentID: String?) -> [MediaItem] {
        guard let currentID, let index = items.firstIndex(where: { $0.id == currentID }) else {
            return Array(items.prefix(8))
        }
        let range = max(0, index - 2)...min(items.count - 1, index + 8)
        return range.map { items[$0] }
    }

    private func writePhotoPreview(source: URL, destination: URL, maxPixelSize: Int) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ] as CFDictionary
              ) else {
            throw MediaPreviewCacheError.cannotCreateImage(source)
        }
        try writeJPEG(image, destination: destination, quality: 0.88)
    }

    private func writeVideoPoster(source: URL, destination: URL, maxPixelSize: Int) throws {
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let duration = asset.duration.seconds.isFinite ? asset.duration.seconds : 0
        let time = CMTime(seconds: min(max(duration * 0.1, 0), 1.0), preferredTimescale: 600)
        do {
            let image = try generator.copyCGImage(at: time, actualTime: nil)
            try writeJPEG(image, destination: destination, quality: 0.82)
        } catch {
            throw MediaPreviewCacheError.cannotCreateImage(source)
        }
    }

    private func writeJPEG(_ image: CGImage, destination: URL, quality: CGFloat) throws {
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try? FileManager.default.removeItem(at: temporary)
        guard let destinationRef = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw MediaPreviewCacheError.cannotCreateDestination(destination)
        }
        CGImageDestinationAddImage(destinationRef, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else {
            try? FileManager.default.removeItem(at: temporary)
            throw MediaPreviewCacheError.cannotCreateDestination(destination)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private func isReadableJPEG(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
    }

    private func evictIfNeeded() throws {
        let files = cacheFiles()
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxBytes else { return }

        var remaining = total
        for file in files.sorted(by: { $0.lastUseDate < $1.lastUseDate }) {
            try? FileManager.default.removeItem(at: file.url)
            remaining -= file.size
            if remaining <= maxBytes { break }
        }
    }

    private func cacheFiles() -> [(url: URL, size: Int64, lastUseDate: Date)] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { entry in
            guard let url = entry as? URL,
                  url.pathExtension.lowercased() == "jpg",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                return nil
            }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func cacheKey(for item: MediaItem) -> String {
        let payload = "\(item.relativePath)|\(item.fileSize)|\(item.captureDate.timeIntervalSince1970)"
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
