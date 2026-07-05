import AVFoundation
import AppKit
import Foundation
import SDReviewCore
import SwiftUI

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
    @Published var isZoomed = false
    @Published var showingExport = false
    @Published var exportDestination: URL = AppModel.defaultExportDestination()
    @Published var flatExport = false
    @Published var isExporting = false
    @Published var exportMessage: String?

    private let scanner = MediaScanner()
    private let sessionStore = SessionStore()
    private let exporter = MediaExporter()
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

    var estimatedExportBytes: Int64 {
        guard let document else { return 0 }
        return exporter.estimateBytes(document: document)
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
        let range = DateRange(start: startDate, end: endDate)

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try MediaScanner().scan(source: sourceURL, dateRange: range)
                }.value

                let loaded = try sessionStore.load(sourceRoot: result.sourceRoot, dateRange: range)
                let document = loaded ?? SessionDocument(
                    sourceRoot: result.sourceRoot,
                    dateRange: range,
                    items: result.items,
                    rawFiles: result.rawFiles,
                    heifFiles: result.heifFiles,
                    problems: result.problems
                )
                reviewSession = ReviewSession(document: document)
                revision += 1
                configurePlayerForCurrentItem(autoplay: true)
            } catch {
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }

    func resetSession() {
        guard let document else { return }
        do {
            try sessionStore.reset(sourceRoot: document.sourceRoot, dateRange: document.dateRange)
            reviewSession = nil
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
        } else {
            session.markRejectOrToggle()
        }
        afterSessionChange(autoplay: true)
    }

    func cycleFilter() {
        guard let session = reviewSession else { return }
        session.cycleFilter()
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
        if let ratio = aspect.ratio {
            let centerX = draftCrop.x + draftCrop.width / 2
            let centerY = draftCrop.y + draftCrop.height / 2
            var width = draftCrop.width
            var height = width / ratio
            if height > 0.9 {
                height = min(0.9, draftCrop.height)
                width = height * ratio
            }
            draftCrop.width = min(width, 0.95)
            draftCrop.height = min(height, 0.95)
            draftCrop.x = centerX - draftCrop.width / 2
            draftCrop.y = centerY - draftCrop.height / 2
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
        jump(seconds: Double(delta) / 30.0)
    }

    func markIn() {
        let now = currentPlaybackSeconds
        if let selectedSegmentID {
            reviewSession?.replaceSegment(segmentID: selectedSegmentID, start: now)
            afterSessionChange(autoplay: false)
        } else {
            pendingIn = now
        }
    }

    func markOut() {
        let now = currentPlaybackSeconds
        if let selectedSegmentID {
            reviewSession?.replaceSegment(segmentID: selectedSegmentID, end: now)
            afterSessionChange(autoplay: false)
        } else {
            pendingOut = now
        }
    }

    func bankPendingSegment() {
        guard let pendingIn, let pendingOut else { return }
        reviewSession?.addSegment(start: pendingIn, end: pendingOut)
        self.pendingIn = nil
        self.pendingOut = nil
        afterSessionChange(autoplay: false)
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
        showingExport = true
    }

    func runExport() {
        guard let document else { return }
        isExporting = true
        exportMessage = nil
        let options = ExportOptions(destination: exportDestination, flatMediaFolder: flatExport)
        Task {
            do {
                let report = try await exporter.export(document: document, options: options)
                exportMessage = "Exported \(report.manifest.items.reduce(0) { $0 + $1.outputFilenames.count }) files to \(report.destination.path)."
            } catch {
                exportMessage = error.localizedDescription
            }
            isExporting = false
        }
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
            shift ? draftCrop.resize(dw: -step, dh: 0) : draftCrop.move(dx: -step, dy: 0)
        case 124:
            shift ? draftCrop.resize(dw: step, dh: 0) : draftCrop.move(dx: step, dy: 0)
        case 125:
            shift ? draftCrop.resize(dw: 0, dh: step) : draftCrop.move(dx: 0, dy: step)
        case 126:
            shift ? draftCrop.resize(dw: 0, dh: -step) : draftCrop.move(dx: 0, dy: -step)
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

    private func afterSessionChange(autoplay: Bool) {
        revision += 1
        pendingIn = nil
        pendingOut = nil
        selectedSegmentID = nil
        persist()
        configurePlayerForCurrentItem(autoplay: autoplay)
    }

    private func persist() {
        guard let document else { return }
        do {
            try sessionStore.save(document, dateRange: document.dateRange)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func configurePlayerForCurrentItem(autoplay: Bool) {
        guard let item = currentItem, item.kind == .video else {
            player?.pause()
            player = nil
            currentPlaybackSeconds = 0
            return
        }
        let nextPlayer = AVPlayer(url: item.fileURL)
        nextPlayer.isMuted = isMuted
        nextPlayer.actionAtItemEnd = .pause
        player = nextPlayer
        currentPlaybackSeconds = 0
        if autoplay {
            nextPlayer.playImmediately(atRate: playbackRate)
        }
    }

    private static func defaultFixtureURL() -> URL? {
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
}
