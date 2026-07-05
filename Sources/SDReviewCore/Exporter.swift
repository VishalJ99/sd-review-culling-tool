import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ExportOptions: Sendable {
    public var destination: URL
    public var flatMediaFolder: Bool
    public var videoHandleSeconds: Double

    public init(destination: URL, flatMediaFolder: Bool = false, videoHandleSeconds: Double = 1.0) {
        self.destination = destination
        self.flatMediaFolder = flatMediaFolder
        self.videoHandleSeconds = videoHandleSeconds
    }
}

public struct ExportedManifestItem: Codable, Equatable, Sendable {
    public var sourceRelativePath: String
    public var fileSize: Int64
    public var sha256: String
    public var decision: ReviewDecision
    public var crop: NormalizedCropRect?
    public var segments: [VideoSegment]
    public var cutMode: String?
    public var outputFilenames: [String]
}

public struct ExportManifest: Codable, Equatable, Sendable {
    public var toolVersion: String
    public var exportedAt: Date
    public var sourceRoot: String
    public var items: [ExportedManifestItem]
    public var failures: [String]
}

public struct ExportReport: Equatable, Sendable {
    public var manifest: ExportManifest
    public var destination: URL
}

public enum ExportError: Error, LocalizedError {
    case zeroKeepers
    case cannotReadImage(URL)
    case cannotCreateDestination(URL)
    case videoExporterUnavailable(URL)
    case videoExportFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .zeroKeepers: "No kept items to export."
        case .cannotReadImage(let url): "Cannot read image: \(url.path)"
        case .cannotCreateDestination(let url): "Cannot create destination: \(url.path)"
        case .videoExporterUnavailable(let url): "Cannot create passthrough exporter for \(url.lastPathComponent)."
        case .videoExportFailed(let url, let message): "Video export failed for \(url.lastPathComponent): \(message)"
        }
    }
}

public final class MediaExporter {
    public init() {}

    public func estimateBytes(document: SessionDocument) -> Int64 {
        document.items
            .filter { $0.isKeptForExport }
            .reduce(Int64(0)) { total, item in
                if item.kind == .video, !item.segments.isEmpty {
                    let fullDuration = max(videoDurationSeconds(url: item.fileURL), 1)
                    let selectedDuration = item.segments.reduce(0) { $0 + $1.durationSeconds }
                    let ratio = min(max(selectedDuration / fullDuration, 0), 1)
                    return total + Int64(Double(item.fileSize) * ratio)
                }
                return total + item.fileSize
            }
    }

    public func export(document: SessionDocument, options: ExportOptions) async throws -> ExportReport {
        let keptItems = document.items.filter { $0.isKeptForExport }
        guard !keptItems.isEmpty else { throw ExportError.zeroKeepers }

        try FileManager.default.createDirectory(at: options.destination, withIntermediateDirectories: true)
        if !options.flatMediaFolder {
            try FileManager.default.createDirectory(at: options.destination.appendingPathComponent("photos"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: options.destination.appendingPathComponent("videos"), withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: options.destination.appendingPathComponent("media"), withIntermediateDirectories: true)
        }

        var manifestItems: [ExportedManifestItem] = []
        var failures: [String] = []
        var usedNames: Set<String> = []

        for item in keptItems {
            do {
                let outputs = try await export(item: item, options: options, usedNames: &usedNames)
                let hash = (try? sha256File(item.fileURL)) ?? ""
                manifestItems.append(
                    ExportedManifestItem(
                        sourceRelativePath: item.relativePath,
                        fileSize: item.fileSize,
                        sha256: hash,
                        decision: item.decision,
                        crop: item.crop,
                        segments: item.segments,
                        cutMode: item.kind == .video && !item.segments.isEmpty ? "passthrough-with-handles" : nil,
                        outputFilenames: outputs.map { $0.lastPathComponent }
                    )
                )
            } catch {
                failures.append("\(item.relativePath): \(error.localizedDescription)")
            }
        }

        let manifest = ExportManifest(
            toolVersion: sdReviewToolVersion,
            exportedAt: Date(),
            sourceRoot: document.sourceRoot,
            items: manifestItems,
            failures: failures
        )
        try writeManifest(manifest, to: options.destination.appendingPathComponent("manifest.json"))
        return ExportReport(manifest: manifest, destination: options.destination)
    }

    private func export(item: MediaItem, options: ExportOptions, usedNames: inout Set<String>) async throws -> [URL] {
        switch item.kind {
        case .photo:
            let name = uniqueName(baseName(for: item, suffix: "jpg"), usedNames: &usedNames)
            let target = folder(for: item, options: options).appendingPathComponent(name)
            if item.crop == nil {
                try copyIfNeeded(source: item.fileURL, destination: target)
            } else {
                try exportCroppedPhoto(item: item, destination: target)
            }
            return [target]
        case .video:
            if item.segments.isEmpty {
                let name = uniqueName(baseName(for: item, suffix: "mov"), usedNames: &usedNames)
                let target = folder(for: item, options: options).appendingPathComponent(name)
                try copyIfNeeded(source: item.fileURL, destination: target)
                return [target]
            }

            var outputs: [URL] = []
            let duration = videoDurationSeconds(url: item.fileURL)
            for (index, segment) in item.segments.sorted(by: { $0.startSeconds < $1.startSeconds }).enumerated() {
                let name = uniqueName(baseName(for: item, clipIndex: index + 1, suffix: "mov"), usedNames: &usedNames)
                let target = folder(for: item, options: options).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path),
                   let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > 0 {
                    outputs.append(target)
                    continue
                }
                try await exportVideoSegment(
                    source: item.fileURL,
                    destination: target,
                    start: max(0, segment.startSeconds - options.videoHandleSeconds),
                    end: min(duration, segment.endSeconds + options.videoHandleSeconds)
                )
                outputs.append(target)
            }
            return outputs
        }
    }

    private func folder(for item: MediaItem, options: ExportOptions) -> URL {
        if options.flatMediaFolder {
            return options.destination.appendingPathComponent("media", isDirectory: true)
        }
        return options.destination.appendingPathComponent(item.kind == .photo ? "photos" : "videos", isDirectory: true)
    }

    private func baseName(for item: MediaItem, clipIndex: Int? = nil, suffix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: item.captureDate)
        let stem = URL(fileURLWithPath: item.filename).deletingPathExtension().lastPathComponent
        if let clipIndex {
            return "\(timestamp)_\(stem)_c\(String(format: "%02d", clipIndex)).\(suffix)"
        }
        return "\(timestamp)_\(stem).\(suffix)"
    }

    private func uniqueName(_ proposed: String, usedNames: inout Set<String>) -> String {
        if !usedNames.contains(proposed) {
            usedNames.insert(proposed)
            return proposed
        }
        let url = URL(fileURLWithPath: proposed)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        while true {
            let candidate = "\(stem)_\(index).\(ext)"
            if !usedNames.contains(candidate) {
                usedNames.insert(candidate)
                return candidate
            }
            index += 1
        }
    }

    private func copyIfNeeded(source: URL, destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path),
           let sourceSize = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           let destinationSize = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           sourceSize == destinationSize {
            return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func exportCroppedPhoto(item: MediaItem, destination: URL) throws {
        guard let crop = item.crop,
              let source = CGImageSourceCreateWithURL(item.fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExportError.cannotReadImage(item.fileURL)
        }
        let cropRect = CGRect(
            x: Double(image.width) * crop.x,
            y: Double(image.height) * crop.y,
            width: Double(image.width) * crop.width,
            height: Double(image.height) * crop.height
        ).integral
        guard let cropped = image.cropping(to: cropRect) else {
            throw ExportError.cannotReadImage(item.fileURL)
        }

        guard let destinationRef = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.cannotCreateDestination(destination)
        }

        var metadata = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        metadata[kCGImagePropertyOrientation] = 1
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyExifDictionary: metadata[kCGImagePropertyExifDictionary] as Any,
            kCGImagePropertyTIFFDictionary: metadata[kCGImagePropertyTIFFDictionary] as Any,
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destinationRef, cropped, options as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else {
            throw ExportError.cannotCreateDestination(destination)
        }
    }

    private func exportVideoSegment(source: URL, destination: URL, start: Double, end: Double) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.videoExporterUnavailable(source)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        session.outputURL = destination
        session.outputFileType = .mov
        let startTime = CMTime(seconds: start, preferredTimescale: 600)
        let endTime = CMTime(seconds: max(start, end), preferredTimescale: 600)
        session.timeRange = CMTimeRangeFromTimeToTime(start: startTime, end: endTime)

        await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        if session.status != .completed {
            throw ExportError.videoExportFailed(source, session.error?.localizedDescription ?? "unknown error")
        }
    }

    private func videoDurationSeconds(url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        return asset.duration.seconds.isFinite ? asset.duration.seconds : 0
    }

    private func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func writeManifest(_ manifest: ExportManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }
}
