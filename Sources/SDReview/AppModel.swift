import AVFoundation
import AppKit
import Foundation
import SDReviewCore
import SwiftUI

enum VideoSegmentEdge {
    case start
    case end
}

@MainActor
final class AppModel: ObservableObject {
    @Published var detectedSources: [URL] = []
    @Published var sourceURL: URL?
    @Published var startDate: Date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @Published var endDate: Date = Date()
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var reviewSession: ReviewSession?
    @Published var revision = 0
    @Published var player: AVPlayer?
    @Published var currentPlaybackSeconds: Double = 0
    @Published var playbackRate: Float = 1
    @Published var isMuted = false
    @Published var pendingIn: Double?
    @Published var pendingOut: Double?
    @Published var selectedSegmentID: UUID?
    @Published var isCropMode = false
    @Published var draftCrop = NormalizedCropRect(x: 0.12, y: 0.18, width: 0.76, height: 0.54, aspect: .sixteenNine)
    @Published var currentPhotoAspect: Double?
    @Published var isZoomed = false
    @Published var zoomAnchor = UnitPoint.center
    @Published var showingExport = false
    @Published var exportDestination: URL = AppModel.defaultExportDestination()
    @Published var flatExport = false
    @Published var isExporting = false
    @Published var exportMessage: String?
    @Published var cacheRevision = 0
    @Published var exportCompletedItems = 0
    @Published var exportTotalItems = 0
    @Published var exportCurrentPath: String?
    @Published var exportFailures: [String] = []
    @Published var showingProblems = false
    @Published var showingSettings = false
    @Published var isGridView = false
    @Published var sourceUnavailable = false
    @Published var resumeMessage: String?
    @Published var showingResumeOffer = false
    @Published var pendingResumeDocument: SessionDocument?
    @Published var pendingFreshDocument: SessionDocument?
    @Published var currentVideoFrameDuration = 1.0 / 30.0
    @Published var videoTimeOffsetHours: Double = AppModel.defaultDouble(key: "videoTimeOffsetHours", defaultValue: 0) {
        didSet { UserDefaults.standard.set(videoTimeOffsetHours, forKey: AppModel.defaultsKey("videoTimeOffsetHours")) }
    }
    @Published var videoHandleSeconds: Double = AppModel.defaultDouble(key: "videoHandleSeconds", defaultValue: 1) {
        didSet { UserDefaults.standard.set(videoHandleSeconds, forKey: AppModel.defaultsKey("videoHandleSeconds")) }
    }
    @Published var cacheLimitGB: Double = AppModel.defaultDouble(key: "cacheLimitGB", defaultValue: 5) {
        didSet {
            UserDefaults.standard.set(cacheLimitGB, forKey: AppModel.defaultsKey("cacheLimitGB"))
            if let document {
                configurePreviewCache(for: document)
                warmCacheAroundCurrent()
            }
        }
    }

    private let scanner = MediaScanner()
    private let sessionStore = SessionStore()
    private let exporter = MediaExporter()
    private var previewCache: MediaPreviewCache?
    private var cacheWarmTask: Task<Bool, Never>?
    private var keyboardMonitor: Any?

    init() {
        refreshSources()
        if let fixture = Self.defaultFixtureURL() {
            sourceURL = fixture
        } else {
            sourceURL = detectedSources.first
        }
    }

    deinit {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
    }

    var document: SessionDocument? {
        reviewSession?.document
    }

    var currentItem: MediaItem? {
        reviewSession?.currentItem
    }

    var filteredItems: [MediaItem] {
        reviewSession?.filteredItems ?? []
    }

    var selectedSegment: VideoSegment? {
        guard let id = selectedSegmentID else { return nil }
        return currentItem?.segments.first { $0.id == id }
    }

    var videoDurationSeconds: Double {
        guard let duration = player?.currentItem?.duration.seconds, duration.isFinite else {
            return 0
        }
        return duration
    }

    var canExport: Bool {
        (document?.items.contains { $0.decision == .keep } ?? false) && !isExporting
    }

    var exportProgressFraction: Double {
        guard exportTotalItems > 0 else { return 0 }
        return Double(exportCompletedItems) / Double(exportTotalItems)
    }

    var estimatedExportBytes: Int64 {
        guard let document else { return 0 }
        return exporter.estimateBytes(document: document)
    }

    func cachedImageURL(for item: MediaItem, variant: CacheVariant) -> URL? {
        previewCache?.existingURL(for: item, variant: variant)
    }

    func ensureCachedImage(for item: MediaItem, variant: CacheVariant) {
        guard let previewCache, previewCache.existingURL(for: item, variant: variant) == nil else {
            return
        }
        let generationTask = Task.detached(priority: variant == .preview ? .userInitiated : .utility) { [previewCache, item, variant] in
            _ = try? previewCache.ensureCachedImage(for: item, variant: variant)
        }
        Task { [weak self] in
            await generationTask.value
            self?.cacheRevision += 1
        }
    }

    var warningSummary: String? {
        guard let document else { return nil }
        var parts: [String] = []
        if !document.rawFiles.isEmpty {
            parts.append("\(document.rawFiles.count) RAW")
        }
        if !document.heifFiles.isEmpty {
            parts.append("\(document.heifFiles.count) HEIF unsupported")
        }
        if !document.problems.isEmpty {
            parts.append("\(document.problems.count) problems")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }

    func refreshSources() {
        detectedSources = scanner.mountedDCIMVolumes()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an SD card, a DCIM folder, or a copied test fixture."
        if panel.runModal() == .OK {
            sourceURL = panel.url
        }
    }

    func scanSelectedSource() {
        guard let sourceURL else {
            errorMessage = "Choose a source folder first."
            return
        }
        isScanning = true
        errorMessage = nil
        exportMessage = nil
        showingResumeOffer = false
        pendingResumeDocument = nil
        pendingFreshDocument = nil
        let range = scanDateRange()
        let videoOffsetSeconds = videoTimeOffsetHours * 3600

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try MediaScanner(videoTimeOffsetSeconds: videoOffsetSeconds).scan(source: sourceURL, dateRange: range)
                }.value

                let loaded = try sessionStore.load(sourceRoot: result.sourceRoot, dateRange: range, cardFingerprint: result.cardFingerprint)
                let freshDocument = SessionDocument(
                    sourceRoot: result.sourceRoot,
                    cardFingerprint: result.cardFingerprint,
                    dateRange: range,
                    items: result.items,
                    rawFiles: result.rawFiles,
                    heifFiles: result.heifFiles,
                    problems: result.problems
                )
                if let loaded {
                    pendingFreshDocument = freshDocument
                    pendingResumeDocument = merge(fresh: freshDocument, loaded: loaded)
                    reviewSession = nil
                    resumeMessage = nil
                    previewCache = nil
                    sourceUnavailable = false
                    revision += 1
                    showingResumeOffer = true
                } else {
                    applyScannedDocument(freshDocument, resumed: false)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }

    func acceptResumeOffer() {
        guard let document = pendingResumeDocument else {
            cancelResumeOffer()
            return
        }
        clearPendingResume()
        applyScannedDocument(document, resumed: true)
        persist()
    }

    func startFreshFromResumeOffer() {
        guard let document = pendingFreshDocument else {
            cancelResumeOffer()
            return
        }
        do {
            try sessionStore.reset(sourceRoot: document.sourceRoot, dateRange: document.dateRange, cardFingerprint: document.cardFingerprint)
            clearPendingResume()
            applyScannedDocument(document, resumed: false)
            persist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelResumeOffer() {
        clearPendingResume()
        revision += 1
    }

    func resetSession() {
        guard let document else { return }
        do {
            try sessionStore.reset(sourceRoot: document.sourceRoot, dateRange: document.dateRange, cardFingerprint: document.cardFingerprint)
            reviewSession = nil
            previewCache = nil
            resumeMessage = nil
            sourceUnavailable = false
            revision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event: event) ? nil : event
        }
    }

    func tickPlayback() {
        currentPlaybackSeconds = player?.currentTime().seconds ?? 0
        verifySourceAvailability()
    }

    func moveNext() {
        guard let session = reviewSession else { return }
        session.moveNext()
        afterSessionChange(autoplay: true)
    }

    func movePrevious() {
        guard let session = reviewSession else { return }
        session.movePrevious()
        afterSessionChange(autoplay: true)
    }

    func jump(to item: MediaItem) {
        reviewSession?.jumpToItem(id: item.id)
        afterSessionChange(autoplay: true)
    }

    func toggleGridView() {
        isGridView.toggle()
        revision += 1
    }

    func showRejectsForSkim() {
        guard let session = reviewSession else { return }
        showingExport = false
        session.filter = .rejects
        isGridView = true
        revision += 1
        persist()
        configurePlayerForCurrentItem(autoplay: false)
        warmCacheAroundCurrent()
    }

    func markKeep() {
        guard let session = reviewSession else { return }
        session.markKeepOrToggle()
        afterSessionChange(autoplay: true)
    }

    func markReject() {
        guard let session = reviewSession else { return }
        if let selectedSegmentID {
            session.removeSegment(segmentID: selectedSegmentID)
            self.selectedSegmentID = nil
            afterSessionChange(autoplay: false, preservePlayer: true)
        } else {
            session.markRejectOrToggle()
            afterSessionChange(autoplay: true)
        }
    }

    func cycleFilter() {
        guard let session = reviewSession else { return }
        session.cycleFilter()
        afterSessionChange(autoplay: true)
    }

    func setFilter(_ filter: TimelineFilter) {
        guard let session = reviewSession else { return }
        session.filter = filter
        afterSessionChange(autoplay: true)
    }

    func undo() {
        reviewSession?.undo()
        afterSessionChange(autoplay: false)
    }

    func redo() {
        reviewSession?.redo()
        afterSessionChange(autoplay: false)
    }

    func beginCropMode() {
        guard currentItem?.kind == .photo else { return }
        draftCrop = currentItem?.crop ?? NormalizedCropRect(x: 0.12, y: 0.18, width: 0.76, height: 0.54, aspect: .sixteenNine)
        isCropMode = true
        isZoomed = false
    }

    func confirmCrop() {
        reviewSession?.setCrop(draftCrop)
        isCropMode = false
        afterSessionChange(autoplay: false)
    }

    func cancelCrop() {
        isCropMode = false
        revision += 1
    }

    func resetCrop() {
        reviewSession?.setCrop(nil)
        isCropMode = false
        afterSessionChange(autoplay: false)
    }

    func setCropAspect(_ aspect: CropAspect) {
        draftCrop.aspect = aspect
        let ratio = aspect == .original ? currentPhotoAspect : aspect.ratio
        if let ratio {
            applyAspectRatio(ratio)
        }
        draftCrop.clamp()
        revision += 1
    }

    func updateDraftCropFromUnitRect(_ rect: CGRect) {
        draftCrop.x = rect.minX
        draftCrop.y = rect.minY
        draftCrop.width = rect.width
        draftCrop.height = rect.height
        draftCrop.clamp()
        revision += 1
    }

    func setCurrentPhotoAspect(width: CGFloat, height: CGFloat) {
        guard width > 0, height > 0 else { return }
        currentPhotoAspect = Double(width / height)
    }

    func updateZoomAnchor(location: CGPoint, containerSize: CGSize) {
        guard containerSize.width > 0, containerSize.height > 0 else { return }
        let x = min(max(location.x / containerSize.width, 0), 1)
        let y = min(max(location.y / containerSize.height, 0), 1)
        zoomAnchor = UnitPoint(x: x, y: y)
    }

    func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.playImmediately(atRate: playbackRate)
        }
    }

    func changePlaybackRate(delta: Float) {
        playbackRate = min(max(playbackRate + delta, 0.5), 2.0)
        if player?.timeControlStatus == .playing {
            player?.rate = playbackRate
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    func jump(seconds: Double) {
        guard let player else { return }
        let next = max(0, min(videoDurationSeconds, currentPlaybackSeconds + seconds))
        player.seek(to: CMTime(seconds: next, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentPlaybackSeconds = next
    }

    func stepFrame(delta: Int) {
        jump(seconds: Double(delta) * currentVideoFrameDuration)
    }

    func markIn() {
        guard currentItem?.kind == .video else { return }
        let now = currentPlaybackSeconds
        if let selectedSegmentID {
            reviewSession?.replaceSegment(segmentID: selectedSegmentID, start: now)
            afterSessionChange(autoplay: false, preservePlayer: true)
        } else {
            pendingIn = now
        }
    }

    func markOut() {
        guard currentItem?.kind == .video else { return }
        let now = currentPlaybackSeconds
        if let selectedSegmentID {
            reviewSession?.replaceSegment(segmentID: selectedSegmentID, end: now)
            afterSessionChange(autoplay: false, preservePlayer: true)
        } else {
            pendingOut = now
        }
    }

    func bankPendingSegment() {
        guard currentItem?.kind == .video else { return }
        guard let pendingIn, let pendingOut else { return }
        reviewSession?.addSegment(start: pendingIn, end: pendingOut)
        self.pendingIn = nil
        self.pendingOut = nil
        afterSessionChange(autoplay: false, preservePlayer: true)
    }

    func selectNextSegment(delta: Int) {
        guard let segments = currentItem?.segments, !segments.isEmpty else { return }
        if let selectedSegmentID,
           let index = segments.firstIndex(where: { $0.id == selectedSegmentID }) {
            let nextIndex = (index + delta + segments.count) % segments.count
            self.selectedSegmentID = segments[nextIndex].id
        } else {
            self.selectedSegmentID = delta < 0 ? segments.last?.id : segments.first?.id
        }
        if let selectedSegment {
            player?.seek(to: CMTime(seconds: selectedSegment.startSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        revision += 1
    }

    func clearVideoSelectionOrPending() {
        if selectedSegmentID != nil {
            selectedSegmentID = nil
        } else if pendingIn != nil || pendingOut != nil {
            pendingIn = nil
            pendingOut = nil
        } else if isCropMode {
            isCropMode = false
        }
        revision += 1
    }

    func prepareExport() {
        exportDestination = Self.defaultExportDestination()
        exportCompletedItems = 0
        exportTotalItems = document?.items.filter { $0.isKeptForExport }.count ?? 0
        exportCurrentPath = nil
        exportFailures = []
        exportMessage = nil
        showingExport = true
    }

    func runExport() {
        guard let document else { return }
        isExporting = true
        exportMessage = nil
        exportCompletedItems = 0
        exportTotalItems = document.items.filter { $0.isKeptForExport }.count
        exportCurrentPath = nil
        exportFailures = []
        let options = ExportOptions(
            destination: exportDestination,
            flatMediaFolder: flatExport,
            videoHandleSeconds: videoHandleSeconds
        )
        Task {
            do {
                let report = try await exporter.export(document: document, options: options) { progress in
                    await MainActor.run {
                        self.exportCompletedItems = progress.completedItems
                        self.exportTotalItems = progress.totalItems
                        self.exportCurrentPath = progress.currentRelativePath
                        self.exportFailures = progress.failures
                    }
                }
                exportFailures = report.manifest.failures
                exportMessage = "Exported \(report.manifest.items.reduce(0) { $0 + $1.outputFilenames.count }) files to \(report.destination.path)."
            } catch {
                exportMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    func seekVideo(to seconds: Double) {
        guard let player else { return }
        let next = max(0, min(videoDurationSeconds, seconds))
        player.seek(to: CMTime(seconds: next, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentPlaybackSeconds = next
    }

    func seekVideo(fraction: Double) {
        seekVideo(to: min(max(fraction, 0), 1) * videoDurationSeconds)
    }

    func updateSegmentEdge(segmentID: UUID, edge: VideoSegmentEdge, seconds: Double) {
        guard currentItem?.kind == .video else { return }
        selectedSegmentID = segmentID
        switch edge {
        case .start:
            reviewSession?.replaceSegment(segmentID: segmentID, start: seconds)
        case .end:
            reviewSession?.replaceSegment(segmentID: segmentID, end: seconds)
        }
        persist()
        revision += 1
    }

    private func handle(event: NSEvent) -> Bool {
        guard reviewSession != nil else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)

        if command, key == "z" {
            shift ? redo() : undo()
            return true
        }
        if command, key == "e" {
            prepareExport()
            return true
        }

        if isCropMode {
            return handleCropKey(event: event, key: key, shift: shift, option: option)
        }

        switch event.keyCode {
        case 123:
            movePrevious()
            return true
        case 124:
            moveNext()
            return true
        case 48:
            selectNextSegment(delta: shift ? -1 : 1)
            return true
        case 53:
            clearVideoSelectionOrPending()
            return true
        case 51, 117:
            markReject()
            return true
        default:
            break
        }

        switch key {
        case "k":
            markKeep()
        case "x":
            markReject()
        case "f":
            cycleFilter()
        case "g":
            toggleGridView()
        case " ":
            togglePlay()
        case "[":
            changePlaybackRate(delta: -0.25)
        case "]":
            changePlaybackRate(delta: 0.25)
        case ",":
            shift ? jump(seconds: -1) : stepFrame(delta: -1)
        case ".":
            shift ? jump(seconds: 1) : stepFrame(delta: 1)
        case "i":
            markIn()
        case "o":
            markOut()
        case "a", "\r":
            bankPendingSegment()
        case "m":
            toggleMute()
        case "c":
            beginCropMode()
        case "z":
            isZoomed.toggle()
        case "r":
            resetCrop()
        default:
            return false
        }
        return true
    }

    private func handleCropKey(event: NSEvent, key: String, shift: Bool, option: Bool) -> Bool {
        let step = option ? 0.005 : 0.02
        switch event.keyCode {
        case 123:
            shift ? resizeDraftCrop(dw: -step, dh: 0) : draftCrop.move(dx: -step, dy: 0)
        case 124:
            shift ? resizeDraftCrop(dw: step, dh: 0) : draftCrop.move(dx: step, dy: 0)
        case 125:
            shift ? resizeDraftCrop(dw: 0, dh: step) : draftCrop.move(dx: 0, dy: step)
        case 126:
            shift ? resizeDraftCrop(dw: 0, dh: -step) : draftCrop.move(dx: 0, dy: -step)
        case 36:
            confirmCrop()
            return true
        case 53:
            cancelCrop()
            return true
        default:
            switch key {
            case "1": setCropAspect(.free)
            case "2": setCropAspect(.original)
            case "3": setCropAspect(.sixteenNine)
            case "4": setCropAspect(.square)
            case "5": setCropAspect(.nineSixteen)
            case "r": resetCrop()
            default: return false
            }
            return true
        }
        revision += 1
        return true
    }

    private func resizeDraftCrop(dw: Double, dh: Double) {
        if let ratio = activeDraftCropRatio() {
            let centerX = draftCrop.x + draftCrop.width / 2
            let centerY = draftCrop.y + draftCrop.height / 2
            if abs(dw) >= abs(dh) {
                draftCrop.width += dw
                draftCrop.height = draftCrop.width / ratio
            } else {
                draftCrop.height += dh
                draftCrop.width = draftCrop.height * ratio
            }
            draftCrop.x = centerX - draftCrop.width / 2
            draftCrop.y = centerY - draftCrop.height / 2
            draftCrop.clamp()
        } else {
            draftCrop.resize(dw: dw, dh: dh)
        }
    }

    func activeDraftCropRatio() -> Double? {
        draftCrop.aspect == .original ? currentPhotoAspect : draftCrop.aspect.ratio
    }

    func resizeDraftCropFromHandles(_ crop: NormalizedCropRect) {
        draftCrop = crop
        if let ratio = activeDraftCropRatio() {
            applyAspectRatio(ratio)
        }
        draftCrop.clamp()
        revision += 1
    }

    private func applyAspectRatio(_ ratio: Double) {
        let centerX = draftCrop.x + draftCrop.width / 2
        let centerY = draftCrop.y + draftCrop.height / 2
        var width = draftCrop.width
        var height = width / ratio
        if height > 0.95 {
            height = min(0.95, draftCrop.height)
            width = height * ratio
        }
        draftCrop.width = min(width, 0.95)
        draftCrop.height = min(height, 0.95)
        draftCrop.x = centerX - draftCrop.width / 2
        draftCrop.y = centerY - draftCrop.height / 2
    }

    private func afterSessionChange(autoplay: Bool, preservePlayer: Bool = false) {
        revision += 1
        pendingIn = nil
        pendingOut = nil
        selectedSegmentID = nil
        persist()
        if !preservePlayer {
            configurePlayerForCurrentItem(autoplay: autoplay)
        }
        warmCacheAroundCurrent()
    }

    private func persist() {
        guard let document else { return }
        do {
            try sessionStore.save(document, dateRange: document.dateRange)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyScannedDocument(_ document: SessionDocument, resumed: Bool) {
        reviewSession = ReviewSession(document: document)
        resumeMessage = resumed ? "Resumed saved session." : nil
        sourceUnavailable = false
        configurePreviewCache(for: document)
        revision += 1
        warmCacheAroundCurrent()
        configurePlayerForCurrentItem(autoplay: true)
    }

    private func clearPendingResume() {
        showingResumeOffer = false
        pendingResumeDocument = nil
        pendingFreshDocument = nil
    }

    private func configurePlayerForCurrentItem(autoplay: Bool) {
        guard let item = currentItem, item.kind == .video else {
            player?.pause()
            player = nil
            currentPlaybackSeconds = 0
            currentVideoFrameDuration = 1.0 / 30.0
            return
        }
        let nextPlayer = AVPlayer(url: item.fileURL)
        nextPlayer.isMuted = isMuted
        nextPlayer.actionAtItemEnd = .pause
        player = nextPlayer
        currentPlaybackSeconds = 0
        currentVideoFrameDuration = frameDurationSeconds(for: item.fileURL)
        if autoplay {
            nextPlayer.playImmediately(atRate: playbackRate)
        }
    }

    private func frameDurationSeconds(for url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              track.nominalFrameRate > 0 else {
            return 1.0 / 30.0
        }
        return 1.0 / Double(track.nominalFrameRate)
    }

    private func verifySourceAvailability() {
        guard let document else { return }
        let available = FileManager.default.fileExists(atPath: document.sourceRoot)
        if available {
            if sourceUnavailable {
                sourceUnavailable = false
                errorMessage = nil
            }
            return
        }

        if !sourceUnavailable {
            player?.pause()
            sourceUnavailable = true
            errorMessage = "Source media is unavailable. Reinsert or reconnect the card/copy, then rescan or continue when the path is available."
        }
    }

    private func configurePreviewCache(for document: SessionDocument) {
        guard let fingerprint = document.cardFingerprint else {
            previewCache = nil
            return
        }
        let maxBytes = Int64(max(cacheLimitGB, 0.25) * 1024 * 1024 * 1024)
        previewCache = MediaPreviewCache(cardFingerprint: fingerprint, maxBytes: maxBytes)
        cacheRevision += 1
    }

    private func warmCacheAroundCurrent() {
        guard let previewCache, let document else { return }
        let items = document.items
        let currentID = currentItem?.id
        cacheWarmTask?.cancel()
        cacheWarmTask = Task.detached(priority: .utility) { [previewCache, items, currentID] in
            guard !Task.isCancelled else { return false }
            previewCache.warm(items: items, currentID: currentID)
            return !Task.isCancelled
        }
        guard let cacheWarmTask else { return }
        Task { [weak self] in
            let finished = await cacheWarmTask.value
            if finished {
                self?.cacheRevision += 1
            }
        }
    }

    private func scanDateRange() -> DateRange {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endDay) ?? endDate
        return DateRange(start: start, end: end)
    }

    private func merge(fresh: SessionDocument, loaded: SessionDocument) -> SessionDocument {
        let loadedByID = Dictionary(uniqueKeysWithValues: loaded.items.map { ($0.id, $0) })
        var mergedItems = fresh.items
        for index in mergedItems.indices {
            if let prior = loadedByID[mergedItems[index].id] {
                mergedItems[index].decision = prior.decision
                mergedItems[index].crop = prior.crop
                mergedItems[index].segments = prior.segments
            }
        }

        let freshIDs = Set(fresh.items.map(\.id))
        let loadedIDs = Set(loaded.items.map(\.id))
        let keepUndo = freshIDs == loadedIDs
        return SessionDocument(
            toolVersion: fresh.toolVersion,
            sourceRoot: fresh.sourceRoot,
            cardFingerprint: fresh.cardFingerprint,
            dateRange: fresh.dateRange,
            lastItemID: freshIDs.contains(loaded.lastItemID ?? "") ? loaded.lastItemID : fresh.items.first?.id,
            filter: loaded.filter,
            items: mergedItems,
            rawFiles: fresh.rawFiles,
            heifFiles: fresh.heifFiles,
            problems: fresh.problems,
            undoStack: keepUndo ? loaded.undoStack : [],
            redoStack: keepUndo ? loaded.redoStack : []
        )
    }

    private static func defaultFixtureURL() -> URL? {
        if let fixture = ProcessInfo.processInfo.environment["SDREVIEW_FIXTURE"], !fixture.isEmpty {
            let url = URL(fileURLWithPath: fixture)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local-test-data/sd-last-24h-20260705-1748")
        return FileManager.default.fileExists(atPath: fixture.path) ? fixture : nil
    }

    private static func defaultExportDestination() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let folder = "Export_\(formatter.string(from: Date()))"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/SD Review", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
    }

    private static func defaultsKey(_ key: String) -> String {
        "SDReview.\(key)"
    }

    private static func defaultDouble(key: String, defaultValue: Double) -> Double {
        let key = defaultsKey(key)
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }
        return UserDefaults.standard.double(forKey: key)
    }
}
