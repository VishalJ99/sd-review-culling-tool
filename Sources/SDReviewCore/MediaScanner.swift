import AVFoundation
import Foundation
import ImageIO

public enum MediaScannerError: Error, LocalizedError {
    case missingSource(URL)

    public var errorDescription: String? {
        switch self {
        case .missingSource(let url): "Source folder does not exist: \(url.path)"
        }
    }
}

public final class MediaScanner {
    private let videoTimeOffsetSeconds: Double

    public init(videoTimeOffsetSeconds: Double = 0) {
        self.videoTimeOffsetSeconds = videoTimeOffsetSeconds
    }

    public func scan(source inputURL: URL, dateRange: DateRange? = nil) throws -> ScanResult {
        let sourceURL = inputURL.standardizedFileURL
        guard sourceURL.hasDirectoryPath, FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw MediaScannerError.missingSource(sourceURL)
        }

        let root = scanRoot(for: sourceURL)
        let fileURLs = try mediaFileURLs(under: root)
        let cardFingerprint = CardFingerprint.make(sourceRoot: root, mediaFileURLs: fileURLs)
        var items: [MediaItem] = []
        var rawFiles: [String] = []
        var heifFiles: [String] = []
        var problems: [MediaProblem] = []

        for fileURL in fileURLs {
            let relativePath = relativePath(for: fileURL, root: root)
            let ext = fileURL.pathExtension.lowercased()
            let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
            let fallbackDate = resourceValues.contentModificationDate ?? resourceValues.creationDate ?? .distantPast
            if ext == "raf" {
                if dateRange?.contains(fallbackDate) ?? true {
                    rawFiles.append(relativePath)
                }
                continue
            }
            if ext == "heif" || ext == "heic" {
                if dateRange?.contains(fallbackDate) ?? true {
                    heifFiles.append(relativePath)
                }
                continue
            }

            let fileSize = Int64(resourceValues.fileSize ?? 0)
            let metadataDate: Date?
            let kind: MediaKind

            if ext == "jpg" || ext == "jpeg" {
                kind = .photo
                metadataDate = photoCaptureDate(fileURL: fileURL)
            } else if ext == "mov" {
                kind = .video
                metadataDate = videoCaptureDate(fileURL: fileURL)
            } else {
                continue
            }

            let captureDate: Date
            if kind == .video, let metadataDate {
                captureDate = metadataDate.addingTimeInterval(videoTimeOffsetSeconds)
            } else {
                captureDate = metadataDate ?? fallbackDate
            }
            if let dateRange, !dateRange.contains(captureDate) {
                continue
            }
            if metadataDate == nil {
                problems.append(MediaProblem(relativePath: relativePath, message: "Missing capture metadata; using filesystem date."))
            }

            items.append(
                MediaItem(
                    sourceRoot: root.path,
                    relativePath: relativePath,
                    filename: fileURL.lastPathComponent,
                    kind: kind,
                    captureDate: captureDate,
                    fileSize: fileSize,
                    usedFallbackDate: metadataDate == nil
                )
            )
        }

        items.sort {
            if $0.captureDate != $1.captureDate {
                return $0.captureDate < $1.captureDate
            }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        problems.append(contentsOf: videoTimestampProblems(items: items))

        return ScanResult(
            sourceRoot: root.path,
            cardFingerprint: cardFingerprint,
            items: items,
            rawFiles: rawFiles.sorted(),
            heifFiles: heifFiles.sorted(),
            problems: problems
        )
    }

    public func mountedDCIMVolumes() -> [URL] {
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil
        )) ?? []
        return volumes
            .map { $0.appendingPathComponent("DCIM") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func scanRoot(for sourceURL: URL) -> URL {
        if sourceURL.lastPathComponent.lowercased() == "dcim" {
            return sourceURL
        }
        let dcim = sourceURL.appendingPathComponent("DCIM", isDirectory: true)
        if FileManager.default.fileExists(atPath: dcim.path) {
            return dcim
        }
        return sourceURL
    }

    private func mediaFileURLs(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent.hasPrefix("._") {
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard ["jpg", "jpeg", "mov", "raf", "heif", "heic"].contains(ext) else {
                continue
            }
            urls.append(url)
        }
        return urls
    }

    private func relativePath(for fileURL: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }

    private func photoCaptureDate(fileURL: URL) -> Date? {
        guard let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let dateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
        let subSecond = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String
        return parseCameraDate(dateString, subSecond: subSecond)
    }

    private func videoCaptureDate(fileURL: URL) -> Date? {
        let asset = AVURLAsset(url: fileURL)
        let metadata = asset.commonMetadata + asset.metadata
        let keys: Set<String> = [
            AVMetadataKey.commonKeyCreationDate.rawValue,
            "com.apple.quicktime.creationdate",
            "creationDate"
        ]

        for item in metadata {
            let rawKey = item.commonKey?.rawValue ?? item.key as? String
            guard let rawKey, keys.contains(rawKey), let value = item.stringValue else {
                continue
            }
            if let date = parseISODate(value) ?? parseCameraDate(value, subSecond: nil) {
                return date
            }
        }
        return nil
    }

    private func parseCameraDate(_ value: String?, subSecond: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard var date = formatter.date(from: value) else { return nil }
        if let subSecond, let fractional = Double("0." + subSecond.filter(\.isNumber)) {
            date = date.addingTimeInterval(fractional)
        }
        return date
    }

    private func parseISODate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: value)
    }

    private func videoTimestampProblems(items: [MediaItem]) -> [MediaProblem] {
        guard abs(videoTimeOffsetSeconds) < 0.1 else { return [] }
        let timezoneOffset = Double(TimeZone.current.secondsFromGMT(for: Date()))
        guard abs(timezoneOffset) >= 1800 else { return [] }
        let photos = items.filter { $0.kind == .photo }
        guard !photos.isEmpty else { return [] }

        return items.compactMap { item in
            guard item.kind == .video,
                  let nearestPhoto = nearestPhotoByCameraNumber(to: item, photos: photos) else {
                return nil
            }
            let delta = item.captureDate.timeIntervalSince(nearestPhoto.captureDate)
            guard abs(abs(delta) - abs(timezoneOffset)) <= 15 * 60 else {
                return nil
            }
            return MediaProblem(
                relativePath: item.relativePath,
                message: "Video timestamp is offset from a nearby photo by roughly the local time zone. If ordering looks wrong, set a video time offset in Settings."
            )
        }
    }

    private func nearestPhotoByCameraNumber(to video: MediaItem, photos: [MediaItem]) -> MediaItem? {
        guard let videoNumber = cameraSequenceNumber(video.filename) else { return nil }
        let candidates = photos.compactMap { photo -> (distance: Int, item: MediaItem)? in
            guard let photoNumber = cameraSequenceNumber(photo.filename) else { return nil }
            return (abs(photoNumber - videoNumber), photo)
        }
        guard let closest = candidates.min(by: { $0.distance < $1.distance }),
              closest.distance <= 4 else {
            return nil
        }
        return closest.item
    }

    private func cameraSequenceNumber(_ filename: String) -> Int? {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let digits = stem.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }
}
