import Foundation

public let sdReviewToolVersion = "0.1.0"

public enum MediaKind: String, Codable, Equatable, Sendable {
    case photo
    case video
}

public enum ReviewDecision: String, Codable, CaseIterable, Equatable, Sendable {
    case undecided
    case keep
    case reject
}

public enum TimelineFilter: String, Codable, CaseIterable, Equatable, Sendable {
    case all
    case undecided
    case keeps
    case rejects

    public var label: String {
        switch self {
        case .all: "All"
        case .undecided: "Undecided"
        case .keeps: "Keeps"
        case .rejects: "Rejects"
        }
    }

    public func includes(_ decision: ReviewDecision) -> Bool {
        switch self {
        case .all: true
        case .undecided: decision == .undecided
        case .keeps: decision == .keep
        case .rejects: decision == .reject
        }
    }

    public func next() -> TimelineFilter {
        let values = TimelineFilter.allCases
        let index = values.firstIndex(of: self) ?? 0
        return values[(index + 1) % values.count]
    }
}

public enum CropAspect: String, Codable, CaseIterable, Equatable, Sendable {
    case free
    case original
    case sixteenNine
    case square
    case nineSixteen

    public var label: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .sixteenNine: "16:9"
        case .square: "1:1"
        case .nineSixteen: "9:16"
        }
    }

    public var ratio: Double? {
        switch self {
        case .free, .original: nil
        case .sixteenNine: 16.0 / 9.0
        case .square: 1.0
        case .nineSixteen: 9.0 / 16.0
        }
    }
}

public struct NormalizedCropRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var aspect: CropAspect

    public init(
        x: Double = 0.1,
        y: Double = 0.1,
        width: Double = 0.8,
        height: Double = 0.8,
        aspect: CropAspect = .free
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.aspect = aspect
        clamp()
    }

    public mutating func clamp() {
        width = min(max(width, 0.02), 1.0)
        height = min(max(height, 0.02), 1.0)
        x = min(max(x, 0), 1.0 - width)
        y = min(max(y, 0), 1.0 - height)
    }

    public mutating func move(dx: Double, dy: Double) {
        x += dx
        y += dy
        clamp()
    }

    public mutating func resize(dw: Double, dh: Double) {
        width += dw
        height += dh
        clamp()
    }
}

public struct VideoSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startSeconds: Double
    public var endSeconds: Double

    public init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double) {
        self.id = id
        self.startSeconds = min(startSeconds, endSeconds)
        self.endSeconds = max(startSeconds, endSeconds)
    }

    public var durationSeconds: Double {
        max(0, endSeconds - startSeconds)
    }
}

public struct MediaItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String { relativePath }

    public var sourceRoot: String
    public var relativePath: String
    public var filename: String
    public var kind: MediaKind
    public var captureDate: Date
    public var fileSize: Int64
    public var usedFallbackDate: Bool
    public var decision: ReviewDecision
    public var crop: NormalizedCropRect?
    public var segments: [VideoSegment]

    public init(
        sourceRoot: String,
        relativePath: String,
        filename: String,
        kind: MediaKind,
        captureDate: Date,
        fileSize: Int64,
        usedFallbackDate: Bool = false,
        decision: ReviewDecision = .undecided,
        crop: NormalizedCropRect? = nil,
        segments: [VideoSegment] = []
    ) {
        self.sourceRoot = sourceRoot
        self.relativePath = relativePath
        self.filename = filename
        self.kind = kind
        self.captureDate = captureDate
        self.fileSize = fileSize
        self.usedFallbackDate = usedFallbackDate
        self.decision = decision
        self.crop = crop
        self.segments = segments
    }

    public var fileURL: URL {
        URL(fileURLWithPath: sourceRoot).appendingPathComponent(relativePath)
    }

    public var hasCrop: Bool {
        crop != nil
    }

    public var isKeptForExport: Bool {
        decision == .keep
    }
}

public struct MediaProblem: Codable, Equatable, Identifiable, Sendable {
    public var id: String { relativePath + ":" + message }
    public var relativePath: String
    public var message: String

    public init(relativePath: String, message: String) {
        self.relativePath = relativePath
        self.message = message
    }
}

public struct ScanResult: Codable, Equatable, Sendable {
    public var sourceRoot: String
    public var items: [MediaItem]
    public var rawFiles: [String]
    public var heifFiles: [String]
    public var problems: [MediaProblem]

    public init(
        sourceRoot: String,
        items: [MediaItem],
        rawFiles: [String] = [],
        heifFiles: [String] = [],
        problems: [MediaProblem] = []
    ) {
        self.sourceRoot = sourceRoot
        self.items = items
        self.rawFiles = rawFiles
        self.heifFiles = heifFiles
        self.problems = problems
    }
}

public struct DateRange: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }
}

public struct SessionDocument: Codable, Equatable, Sendable {
    public var toolVersion: String
    public var sourceRoot: String
    public var dateRange: DateRange?
    public var lastItemID: String?
    public var filter: TimelineFilter
    public var items: [MediaItem]
    public var rawFiles: [String]
    public var heifFiles: [String]
    public var problems: [MediaProblem]

    public init(
        toolVersion: String = sdReviewToolVersion,
        sourceRoot: String,
        dateRange: DateRange? = nil,
        lastItemID: String? = nil,
        filter: TimelineFilter = .all,
        items: [MediaItem],
        rawFiles: [String] = [],
        heifFiles: [String] = [],
        problems: [MediaProblem] = []
    ) {
        self.toolVersion = toolVersion
        self.sourceRoot = sourceRoot
        self.dateRange = dateRange
        self.lastItemID = lastItemID
        self.filter = filter
        self.items = items
        self.rawFiles = rawFiles
        self.heifFiles = heifFiles
        self.problems = problems
    }
}
