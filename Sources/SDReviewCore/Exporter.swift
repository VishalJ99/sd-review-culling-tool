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

public struct ExportedOutputFile: Codable, Equatable, Sendable {
    public var filename: String
    public var sizeBytes: Int64
    public var sha256: String
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
    public var outputFiles: [ExportedOutputFile]?
    public var failure: String?
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

public struct ExportProgress: Equatable, Sendable {
    public var completedItems: Int
    public var totalItems: Int
    public var currentRelativePath: String?
    public var failures: [String]

    public init(completedItems: Int, totalItems: Int, currentRelativePath: String?, failures: [String]) {
        self.completedItems = completedItems
        self.totalItems = totalItems
        self.currentRelativePath = currentRelativePath
        self.failures = failures
    }
}

public enum ExportError: Error, LocalizedError {
    case zeroKeepers
    case cannotReadImage(URL)
    case cannotCreateDestination(URL)
    case unsafeDestination(URL)
    case insufficientSpace(required: Int64, available: Int64)
    case videoExporterUnavailable(URL)
    case videoExportFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .zeroKeepers: "No kept items to export."
        case .cannotReadImage(let url): "Cannot read image: \(url.path)"
        case .cannotCreateDestination(let url): "Cannot create destination: \(url.path)"
        case .unsafeDestination(let url): "Export destination would write to the source media volume or source tree: \(url.path)"
        case .insufficientSpace(let required, let available): "Not enough free space. Required \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)); available \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))."
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

    public func export(
        document: SessionDocument,
        options: ExportOptions,
        progress: (@Sendable (ExportProgress) async -> Void)? = nil
    ) async throws -> ExportReport {
        let keptItems = document.items.filter { $0.isKeptForExport }
        guard !keptItems.isEmpty else { throw ExportError.zeroKeepers }
        try validateDestination(options.destination, document: document)
        try validateFreeSpace(options.destination, requiredBytes: estimateBytes(document: document))

        try FileManager.default.createDirectory(at: options.destination, withIntermediateDirectories: true)
        if !options.flatMediaFolder {
            try FileManager.default.createDirectory(at: options.destination.appendingPathComponent("photos"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: options.destination.appendingPathComponent("videos"), withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: options.destination.appendingPathComponent("media"), withIntermediateDirectories: true)
        }

        let manifestURL = options.destination.appendingPathComponent("manifest.json")
        let previousManifest = loadManifest(from: manifestURL)
        var outputMap: [String: [ExportedOutputFile]] = [:]
        var failureMap: [String: String] = [:]
        var failures: [String] = []
        var usedNames: Set<String> = []
        var completedItems = 0
        await progress?(ExportProgress(
            completedItems: completedItems,
            totalItems: keptItems.count,
            currentRelativePath: keptItems.first?.relativePath,
            failures: failures
        ))

        for item in keptItems {
            do {
                outputMap[item.id] = try await export(
                    item: item,
                    options: options,
                    previousManifest: previousManifest,
                    usedNames: &usedNames
                )
            } catch {
                let failure = "\(item.relativePath): \(error.localizedDescription)"
                failures.append(failure)
                failureMap[item.id] = error.localizedDescription
            }
            completedItems += 1
            await progress?(ExportProgress(
                completedItems: completedItems,
                totalItems: keptItems.count,
                currentRelativePath: completedItems < keptItems.count ? keptItems[completedItems].relativePath : nil,
                failures: failures
            ))
        }

        let manifestItems = document.items.map { item in
            let outputs = outputMap[item.id] ?? []
            return ExportedManifestItem(
                sourceRelativePath: item.relativePath,
                fileSize: item.fileSize,
                sha256: (try? sha256File(item.fileURL)) ?? "",
                decision: item.decision,
                crop: item.crop,
                segments: item.segments,
                cutMode: cutMode(for: item),
                outputFilenames: outputs.map(\.filename),
                outputFiles: outputs,
                failure: failureMap[item.id]
            )
        }

        let manifest = ExportManifest(
            toolVersion: sdReviewToolVersion,
            exportedAt: Date(),
            sourceRoot: document.sourceRoot,
            items: manifestItems,
            failures: failures
        )
        try writeManifest(manifest, to: manifestURL)
        return ExportReport(manifest: manifest, destination: options.destination)
    }

    private func export(
        item: MediaItem,
        options: ExportOptions,
        previousManifest: ExportManifest?,
        usedNames: inout Set<String>
    ) async throws -> [ExportedOutputFile] {
        if let previousOutputs = verifiedPreviousOutputs(for: item, options: options, previousManifest: previousManifest) {
            previousOutputs.forEach { usedNames.insert($0.filename) }
            return previousOutputs
        }

        switch item.kind {
        case .photo:
            let name = uniqueName(baseName(for: item, suffix: "jpg"), usedNames: &usedNames)
            let target = folder(for: item, options: options).appendingPathComponent(name)
            if item.crop == nil {
                return [try copyIfNeeded(source: item.fileURL, destination: target)]
            } else {
                return [try exportCroppedPhoto(item: item, destination: target)]
            }
        case .video:
            if item.segments.isEmpty {
                let name = uniqueName(baseName(for: item, suffix: "mov"), usedNames: &usedNames)
                let target = folder(for: item, options: options).appendingPathComponent(name)
                return [try copyIfNeeded(source: item.fileURL, destination: target)]
            }

            var outputs: [ExportedOutputFile] = []
            let duration = videoDurationSeconds(url: item.fileURL)
            for (index, segment) in item.segments.sorted(by: { $0.startSeconds < $1.startSeconds }).enumerated() {
                let name = uniqueName(baseName(for: item, clipIndex: index + 1, suffix: "mov"), usedNames: &usedNames)
                let target = folder(for: item, options: options).appendingPathComponent(name)
                outputs.append(try await exportVideoSegment(
                    source: item.fileURL,
                    destination: target,
                    start: max(0, segment.startSeconds - options.videoHandleSeconds),
                    end: min(duration, segment.endSeconds + options.videoHandleSeconds)
                ))
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

    private func copyIfNeeded(source: URL, destination: URL) throws -> ExportedOutputFile {
        if FileManager.default.fileExists(atPath: destination.path),
           let sourceSize = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           let destinationSize = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           sourceSize == destinationSize,
           (try? sha256File(destination)) == (try? sha256File(source)) {
            return try outputFile(at: destination)
        }
        let temporary = temporaryURL(for: destination)
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: source, to: temporary)
        try replaceFile(at: destination, with: temporary)
        return try outputFile(at: destination)
    }

    private func exportCroppedPhoto(item: MediaItem, destination: URL) throws -> ExportedOutputFile {
        guard let crop = item.crop,
              let source = CGImageSourceCreateWithURL(item.fileURL as CFURL, nil) else {
            throw ExportError.cannotReadImage(item.fileURL)
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxPixelSize = max(pixelWidth, pixelHeight)
        let transformOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, transformOptions as CFDictionary) else {
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

        let temporary = temporaryURL(for: destination)
        try? FileManager.default.removeItem(at: temporary)
        guard let destinationRef = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.cannotCreateDestination(destination)
        }

        var metadata = properties
        metadata[kCGImagePropertyOrientation] = 1
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.92,
            kCGImagePropertyExifDictionary: metadata[kCGImagePropertyExifDictionary] as Any,
            kCGImagePropertyTIFFDictionary: metadata[kCGImagePropertyTIFFDictionary] as Any,
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destinationRef, cropped, options as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ExportError.cannotCreateDestination(destination)
        }
        try replaceFile(at: destination, with: temporary)
        return try outputFile(at: destination)
    }

    private func exportVideoSegment(source: URL, destination: URL, start: Double, end: Double) async throws -> ExportedOutputFile {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.videoExporterUnavailable(source)
        }
        let temporary = temporaryURL(for: destination)
        try? FileManager.default.removeItem(at: temporary)
        session.outputURL = temporary
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
            try? FileManager.default.removeItem(at: temporary)
            throw ExportError.videoExportFailed(source, session.error?.localizedDescription ?? "unknown error")
        }
        try replaceFile(at: destination, with: temporary)
        return try outputFile(at: destination)
    }

    private func verifiedPreviousOutputs(
        for item: MediaItem,
        options: ExportOptions,
        previousManifest: ExportManifest?
    ) -> [ExportedOutputFile]? {
        guard let previous = previousManifest?.items.first(where: { $0.sourceRelativePath == item.relativePath }),
              previous.fileSize == item.fileSize,
              previous.decision == item.decision,
              previous.crop == item.crop,
              previous.segments == item.segments,
              previous.cutMode == cutMode(for: item),
              let outputs = previous.outputFiles,
              !outputs.isEmpty else {
            return nil
        }

        let outputFolder = folder(for: item, options: options)
        for output in outputs {
            let url = outputFolder.appendingPathComponent(output.filename)
            guard FileManager.default.fileExists(atPath: url.path),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  Int64(size) == output.sizeBytes,
                  (try? sha256File(url)) == output.sha256 else {
                return nil
            }
        }
        return outputs
    }

    private func cutMode(for item: MediaItem) -> String? {
        item.kind == .video && !item.segments.isEmpty ? "passthrough-with-handles" : nil
    }

    private func outputFile(at url: URL) throws -> ExportedOutputFile {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return ExportedOutputFile(
            filename: url.lastPathComponent,
            sizeBytes: Int64(values.fileSize ?? 0),
            sha256: try sha256File(url)
        )
    }

    private func temporaryURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    }

    private func replaceFile(at destination: URL, with temporary: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
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

    private func loadManifest(from url: URL) -> ExportManifest? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ExportManifest.self, from: data)
    }

    private func validateDestination(_ destination: URL, document: SessionDocument) throws {
        let destinationURL = destination.standardizedFileURL
        let sourceURL = URL(fileURLWithPath: document.sourceRoot).standardizedFileURL
        let destinationPath = destinationURL.path
        let sourcePath = sourceURL.path
        if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
            throw ExportError.unsafeDestination(destinationURL)
        }

        if sourcePath.hasPrefix("/Volumes/"),
           let sourceVolume = try? sourceURL.resourceValues(forKeys: [.volumeURLKey]).volume,
           let destinationVolume = try? nearestExistingParent(for: destinationURL).resourceValues(forKeys: [.volumeURLKey]).volume,
           sourceVolume.standardizedFileURL == destinationVolume.standardizedFileURL {
            throw ExportError.unsafeDestination(destinationURL)
        }
    }

    private func validateFreeSpace(_ destination: URL, requiredBytes: Int64) throws {
        let parent = nearestExistingParent(for: destination)
        let values = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        if available > 0 && available < requiredBytes {
            throw ExportError.insufficientSpace(required: requiredBytes, available: available)
        }
    }

    private func nearestExistingParent(for url: URL) -> URL {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                break
            }
            candidate = parent
        }
        return candidate
    }
}
