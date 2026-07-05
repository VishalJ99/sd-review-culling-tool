import AVKit
import SDReviewCore
import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    private let playbackTimer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if model.reviewSession == nil {
                SourceSetupView(model: model)
            } else {
                ReviewView(model: model)
            }
        }
        .onAppear { model.installKeyboardMonitor() }
        .onReceive(playbackTimer) { _ in model.tickPlayback() }
        .sheet(isPresented: $model.showingExport) {
            ExportSheet(model: model)
        }
        .sheet(isPresented: $model.showingProblems) {
            ProblemsSheet(model: model)
        }
        .sheet(isPresented: $model.showingSettings) {
            SettingsSheet(model: model)
        }
    }
}

private struct SourceSetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("SD Review")
                    .font(.system(size: 28, weight: .semibold))
                Spacer()
                Button("Refresh") { model.refreshSources() }
                Button("Choose Folder") { model.chooseFolder() }
                Button("Settings") { model.showingSettings = true }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Source")
                    .font(.headline)
                Picker("Source", selection: Binding(
                    get: { model.sourceURL },
                    set: { model.sourceURL = $0 }
                )) {
                    if let sourceURL = model.sourceURL {
                        Text(sourceURL.path).tag(Optional(sourceURL))
                    }
                    ForEach(model.detectedSources, id: \.self) { url in
                        Text(url.path).tag(Optional(url))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                if let sourceURL = model.sourceURL {
                    Text(sourceURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 18) {
                DatePicker("Start", selection: $model.startDate)
                DatePicker("End", selection: $model.endDate)
            }

            HStack {
                Button {
                    model.scanSelectedSource()
                } label: {
                    if model.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.isScanning ? "Scanning" : "Scan & Review")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isScanning || model.sourceURL == nil)

                if let error = model.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .padding(28)
    }
}

private struct ReviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StatusBar(model: model)
            Divider()
            if let item = model.currentItem {
                if model.isGridView {
                    GridSkimView(model: model)
                } else if item.kind == .photo {
                    PhotoReviewPane(model: model, item: item)
                } else {
                    VideoReviewPane(model: model, item: item)
                }
            } else {
                ContentUnavailableView("No items in this filter", systemImage: "line.3.horizontal.decrease.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            FilmstripView(model: model)
            Divider()
            HintBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct StatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let session = model.reviewSession
        let item = model.currentItem
        HStack(spacing: 14) {
            Text("\(session?.currentPosition ?? 0) / \(session?.filteredItems.count ?? 0)")
                .fontWeight(.medium)
            Text(session?.filter.label.lowercased() ?? "all")
            if let item {
                Text(item.captureDate.formatted(date: .abbreviated, time: .shortened))
                Text(item.filename)
                    .font(.system(.body, design: .monospaced))
            }
            if let warning = model.warningSummary {
                Button(warning) { model.showingProblems = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text("\(session?.undecidedCount ?? 0) undecided")
                .foregroundStyle(.secondary)
            StateBadge(decision: item?.decision ?? .undecided, crop: item?.crop != nil, segments: item?.segments.count ?? 0)
            Button(model.isGridView ? "Viewer" : "Grid") { model.toggleGridView() }
                .keyboardShortcut("g", modifiers: [])
            Button("Export") { model.prepareExport() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!model.canExport)
            Button("Settings") { model.showingSettings = true }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }
}

private struct StateBadge: View {
    var decision: ReviewDecision
    var crop: Bool
    var segments: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(decision.rawValue)
            if crop { Text("crop") }
            if segments > 0 { Text("\(segments) clips") }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
        .overlay(Capsule().stroke(border, lineWidth: 0.5))
    }

    private var foreground: Color {
        switch decision {
        case .keep: Color.green.opacity(0.9)
        case .reject: Color.red.opacity(0.9)
        case .undecided: Color.secondary
        }
    }

    private var background: Color {
        switch decision {
        case .keep: Color.green.opacity(0.12)
        case .reject: Color.red.opacity(0.12)
        case .undecided: Color.secondary.opacity(0.10)
        }
    }

    private var border: Color {
        foreground.opacity(0.45)
    }
}

private struct PhotoReviewPane: View {
    @ObservedObject var model: AppModel
    var item: MediaItem

    var body: some View {
        let _ = model.cacheRevision
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let previewURL = model.cachedImageURL(for: item, variant: .preview),
               let image = NSImage(contentsOf: previewURL) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .scaleEffect(model.isZoomed ? 1.9 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: model.isZoomed)
                    .padding(model.isZoomed ? 0 : 20)
            } else {
                ProgressView()
                    .onAppear {
                        model.ensureCachedImage(for: item, variant: .preview)
                    }
            }

            if model.isCropMode {
                CropOverlay(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CropOverlay: View {
    @ObservedObject var model: AppModel
    @State private var dragStart: NormalizedCropRect?

    var body: some View {
        GeometryReader { proxy in
            let rect = displayRect(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.22)
                cropPath(rect: rect)
                    .fill(Color.black.opacity(0.01), style: FillStyle(eoFill: true))
                Rectangle()
                    .path(in: rect)
                    .stroke(Color.white, lineWidth: 1.4)
                RuleOfThirds(rect: rect)
                handles(rect: rect, canvasSize: proxy.size)
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStart == nil { dragStart = model.draftCrop }
                        guard var start = dragStart else { return }
                        start.move(
                            dx: value.translation.width / max(proxy.size.width, 1),
                            dy: value.translation.height / max(proxy.size.height, 1)
                        )
                        model.draftCrop = start
                        model.revision += 1
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .overlay(alignment: .bottom) {
                Text("1-5 aspect  |  arrows move  |  shift+arrows resize  |  return apply  |  esc cancel  |  R reset")
                    .font(.caption)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 12)
            }
        }
    }

    private func displayRect(in size: CGSize) -> CGRect {
        CGRect(
            x: size.width * model.draftCrop.x,
            y: size.height * model.draftCrop.y,
            width: size.width * model.draftCrop.width,
            height: size.height * model.draftCrop.height
        )
    }

    private func cropPath(rect: CGRect) -> Path {
        var path = Path(CGRect(x: 0, y: 0, width: 10_000, height: 10_000))
        path.addRect(rect)
        return path
    }

    private func handles(rect: CGRect, canvasSize: CGSize) -> some View {
        ZStack {
            ForEach(CropHandleKind.allCases, id: \.self) { kind in
                CropResizeHandle(model: model, kind: kind, canvasSize: canvasSize)
                    .position(kind.point(in: rect))
            }
        }
    }
}

private enum CropHandleKind: CaseIterable {
    case topLeft
    case top
    case topRight
    case left
    case right
    case bottomLeft
    case bottom
    case bottomRight

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    var movesLeft: Bool {
        switch self {
        case .topLeft, .left, .bottomLeft: true
        default: false
        }
    }

    var movesRight: Bool {
        switch self {
        case .topRight, .right, .bottomRight: true
        default: false
        }
    }

    var movesTop: Bool {
        switch self {
        case .topLeft, .top, .topRight: true
        default: false
        }
    }

    var movesBottom: Bool {
        switch self {
        case .bottomLeft, .bottom, .bottomRight: true
        default: false
        }
    }
}

private struct CropResizeHandle: View {
    @ObservedObject var model: AppModel
    var kind: CropHandleKind
    var canvasSize: CGSize
    @State private var dragStart: NormalizedCropRect?

    var body: some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 9, height: 9)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = model.draftCrop
                        }
                        guard let dragStart else { return }
                        model.draftCrop = resizedCrop(from: dragStart, translation: value.translation)
                        model.revision += 1
                    }
                    .onEnded { _ in
                        dragStart = nil
                    }
            )
    }

    private func resizedCrop(from start: NormalizedCropRect, translation: CGSize) -> NormalizedCropRect {
        let dx = Double(translation.width / max(canvasSize.width, 1))
        let dy = Double(translation.height / max(canvasSize.height, 1))
        let minSize = 0.02
        var crop = start

        if kind.movesLeft {
            let right = crop.x + crop.width
            let nextX = min(max(crop.x + dx, 0), right - minSize)
            crop.x = nextX
            crop.width = right - nextX
        }
        if kind.movesRight {
            crop.width = min(max(crop.width + dx, minSize), 1 - crop.x)
        }
        if kind.movesTop {
            let bottom = crop.y + crop.height
            let nextY = min(max(crop.y + dy, 0), bottom - minSize)
            crop.y = nextY
            crop.height = bottom - nextY
        }
        if kind.movesBottom {
            crop.height = min(max(crop.height + dy, minSize), 1 - crop.y)
        }
        crop.clamp()
        return crop
    }
}

private struct RuleOfThirds: View {
    var rect: CGRect

    var body: some View {
        Path { path in
            for index in 1...2 {
                let x = rect.minX + rect.width * CGFloat(index) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * CGFloat(index) / 3
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.65), style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
    }
}

private struct VideoReviewPane: View {
    @ObservedObject var model: AppModel
    var item: MediaItem

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                if let player = model.player {
                    VideoPlayer(player: player)
                }
            }
            .frame(minHeight: 280)

            VideoTimeline(model: model, item: item)
                .frame(height: 58)

            SegmentList(model: model, item: item)
                .frame(height: 100)
        }
        .padding(16)
    }
}

private struct VideoTimeline: View {
    @ObservedObject var model: AppModel
    var item: MediaItem

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("\(format(model.currentPlaybackSeconds)) / \(format(model.videoDurationSeconds))  \(String(format: "%.2gx", model.playbackRate))")
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.16))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    model.seekVideo(fraction: value.location.x / max(proxy.size.width, 1))
                                }
                        )
                    ForEach(item.segments) { segment in
                        let rect = segmentRect(segment.startSeconds, segment.endSeconds, duration: model.videoDurationSeconds, width: proxy.size.width)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(segment.id == model.selectedSegmentID ? Color.teal : Color.teal.opacity(0.65))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                        SegmentEdgeHandle(
                            model: model,
                            segment: segment,
                            edge: .start,
                            duration: model.videoDurationSeconds,
                            timelineWidth: proxy.size.width
                        )
                        .offset(x: rect.minX - 3, y: -3)
                        SegmentEdgeHandle(
                            model: model,
                            segment: segment,
                            edge: .end,
                            duration: model.videoDurationSeconds,
                            timelineWidth: proxy.size.width
                        )
                        .offset(x: rect.maxX - 3, y: -3)
                    }
                    if let pendingIn = model.pendingIn, let pendingOut = model.pendingOut {
                        let rect = segmentRect(pendingIn, pendingOut, duration: model.videoDurationSeconds, width: proxy.size.width)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.orange.opacity(0.75))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2)
                        .offset(x: playheadX(duration: model.videoDurationSeconds, width: proxy.size.width))
                }
            }
            .frame(height: 14)
        }
    }

    private func segmentRect(_ start: Double, _ end: Double, duration: Double, width: CGFloat) -> CGRect {
        let safeDuration = max(duration, 0.001)
        let x = CGFloat(min(start, end) / safeDuration) * width
        let w = max(3, CGFloat(abs(end - start) / safeDuration) * width)
        return CGRect(x: x, y: 1, width: w, height: 12)
    }

    private func playheadX(duration: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(CGFloat(model.currentPlaybackSeconds / duration) * width, 0), width)
    }
}

private struct SegmentEdgeHandle: View {
    @ObservedObject var model: AppModel
    var segment: VideoSegment
    var edge: VideoSegmentEdge
    var duration: Double
    var timelineWidth: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(segment.id == model.selectedSegmentID ? 0.95 : 0.75))
            .frame(width: 6, height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.selectedSegmentID = segment.id
                        model.seekVideo(to: targetSeconds(translation: value.translation.width))
                    }
                    .onEnded { value in
                        model.updateSegmentEdge(
                            segmentID: segment.id,
                            edge: edge,
                            seconds: targetSeconds(translation: value.translation.width)
                        )
                    }
            )
    }

    private func targetSeconds(translation: CGFloat) -> Double {
        let base = edge == .start ? segment.startSeconds : segment.endSeconds
        let delta = Double(translation / max(timelineWidth, 1)) * max(duration, 0)
        return min(max(base + delta, 0), max(duration, 0))
    }
}

private struct SegmentList: View {
    @ObservedObject var model: AppModel
    var item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(item.segments.enumerated()), id: \.element.id) { index, segment in
                HStack {
                    Rectangle()
                        .fill(segment.id == model.selectedSegmentID ? Color.teal : Color.teal.opacity(0.65))
                        .frame(width: 10, height: 10)
                    Text("c\(String(format: "%02d", index + 1))")
                        .font(.system(.caption, design: .monospaced))
                    Text("\(format(segment.startSeconds)) - \(format(segment.endSeconds))")
                    Text("\(String(format: "%.1f", segment.durationSeconds)) s")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedSegmentID = segment.id
                    model.revision += 1
                }
            }
            if let pendingIn = model.pendingIn, let pendingOut = model.pendingOut {
                HStack {
                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 10, height: 10)
                    Text("pending")
                    Text("\(format(pendingIn)) - \(format(pendingOut))")
                    Text("press A")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GridSkimView: View {
    @ObservedObject var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.filteredItems) { item in
                    GridSkimTile(model: model, item: item, isCurrent: item.id == model.currentItem?.id)
                        .onTapGesture {
                            model.jump(to: item)
                            model.isGridView = false
                        }
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct GridSkimTile: View {
    @ObservedObject var model: AppModel
    var item: MediaItem
    var isCurrent: Bool

    var body: some View {
        let _ = model.cacheRevision
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                decisionMarker
                    .padding(6)
            }
            Text(item.filename)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
            HStack(spacing: 5) {
                if item.kind == .video {
                    Image(systemName: "video.fill")
                }
                if item.crop != nil {
                    Image(systemName: "crop")
                }
                if !item.segments.isEmpty {
                    Text("\(item.segments.count) clips")
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(7)
        .frame(height: 152)
        .background(tileBackground, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isCurrent ? Color.indigo : Color.secondary.opacity(0.25), lineWidth: isCurrent ? 2 : 0.5))
        .opacity(item.decision == .reject ? 0.55 : 1)
        .onAppear {
            model.ensureCachedImage(for: item, variant: .thumbnail)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = model.cachedImageURL(for: item, variant: .thumbnail),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: item.kind == .photo ? "photo" : "video")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
    }

    private var decisionMarker: some View {
        Circle()
            .fill(item.decision == .keep ? Color.green : item.decision == .reject ? Color.red : Color.secondary.opacity(0.45))
            .frame(width: 10, height: 10)
    }

    private var tileBackground: Color {
        switch item.decision {
        case .keep: Color.green.opacity(0.10)
        case .reject: Color.red.opacity(0.10)
        case .undecided: Color.secondary.opacity(0.07)
        }
    }
}

private struct FilmstripView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(model.filteredItems) { item in
                    FilmstripTile(model: model, item: item, isCurrent: item.id == model.currentItem?.id)
                        .onTapGesture {
                            model.jump(to: item)
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 80)
    }
}

private struct FilmstripTile: View {
    @ObservedObject var model: AppModel
    var item: MediaItem
    var isCurrent: Bool

    var body: some View {
        let _ = model.cacheRevision
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                tileImage
                Spacer()
                decisionMarker
            }
            Spacer()
            Text(item.filename)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
        }
        .padding(6)
        .frame(width: 118, height: 56)
        .background(tileBackground, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isCurrent ? Color.indigo : Color.secondary.opacity(0.25), lineWidth: isCurrent ? 2 : 0.5))
        .opacity(item.decision == .reject ? 0.55 : 1)
        .onAppear {
            model.ensureCachedImage(for: item, variant: .thumbnail)
        }
    }

    @ViewBuilder
    private var tileImage: some View {
        if let url = model.cachedImageURL(for: item, variant: .thumbnail),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: item.kind == .photo ? "photo" : "video")
        }
    }

    private var decisionMarker: some View {
        Circle()
            .fill(item.decision == .keep ? Color.green : item.decision == .reject ? Color.red : Color.secondary.opacity(0.35))
            .frame(width: 8, height: 8)
    }

    private var tileBackground: Color {
        switch item.decision {
        case .keep: Color.green.opacity(0.10)
        case .reject: Color.red.opacity(0.10)
        case .undecided: Color.secondary.opacity(0.08)
        }
    }
}

private struct HintBar: View {
    var body: some View {
        Text("left/right move  |  K keep  |  X reject  |  F filter  |  C crop  |  Z zoom  |  space play  |  I/O mark  |  A bank  |  tab segment  |  cmd+Z undo  |  cmd+E export")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 14)
            .frame(height: 32)
    }
}

private struct ExportSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export selection")
                .font(.headline)

            HStack {
                StatePill(text: "\(model.reviewSession?.keepCount ?? 0) keeps", color: .green)
                Text("\(photoKeepCount) photos - \(clipCount) clips")
                    .foregroundStyle(.secondary)
            }
            HStack {
                StatePill(text: "\(model.reviewSession?.rejectCount ?? 0) rejects", color: .secondary)
                Text("excluded from export")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Review Rejects") { model.showRejectsForSkim() }
                    .disabled((model.reviewSession?.rejectCount ?? 0) == 0 || model.isExporting)
            }

            if (model.reviewSession?.undecidedCount ?? 0) > 0 {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    VStack(alignment: .leading) {
                        Text("\(model.reviewSession?.undecidedCount ?? 0) items still undecided")
                            .fontWeight(.medium)
                        Text("Undecided items are not exported.")
                    }
                }
                .foregroundStyle(.orange)
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Destination")
                    Text(model.exportDestination.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Change") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        model.exportDestination = url
                    }
                }
            }

            Toggle("Flat media/ folder - one chronological list", isOn: $model.flatExport)

            Text("Estimated \(byteCount(model.estimatedExportBytes))")
                .foregroundStyle(.secondary)

            if model.isExporting || model.exportTotalItems > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.exportProgressFraction)
                    HStack {
                        Text("\(model.exportCompletedItems) / \(model.exportTotalItems)")
                        if let path = model.exportCurrentPath {
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let message = model.exportMessage {
                Text(message)
                    .foregroundStyle(message.hasPrefix("Exported") ? .green : .red)
                    .lineLimit(3)
            }

            if !model.exportFailures.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(model.exportFailures.count) export failures")
                        .fontWeight(.medium)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.exportFailures, id: \.self) { failure in
                                Text(failure)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
                .padding(10)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Spacer()
                Button("Cancel") { model.showingExport = false }
                    .disabled(model.isExporting)
                Button(model.isExporting ? "Exporting" : "Export") {
                    model.runExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canExport)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var photoKeepCount: Int {
        model.document?.items.filter { $0.decision == .keep && $0.kind == .photo }.count ?? 0
    }

    private var clipCount: Int {
        model.document?.items.filter { $0.decision == .keep && $0.kind == .video }.reduce(0) { total, item in
            total + max(1, item.segments.count)
        } ?? 0
    }
}

private struct ProblemsSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Problems")
                    .font(.headline)
                Spacer()
                Button("Done") { model.showingProblems = false }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    problemGroup(title: "Unsupported HEIF", values: model.document?.heifFiles ?? [])
                    problemGroup(title: "RAW files ignored", values: model.document?.rawFiles ?? [])
                    let problems = model.document?.problems ?? []
                    if !problems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scanner warnings")
                                .fontWeight(.medium)
                            ForEach(problems) { problem in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(problem.relativePath)
                                        .font(.system(.caption, design: .monospaced))
                                    Text(problem.message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if (model.document?.heifFiles.isEmpty ?? true),
                       (model.document?.rawFiles.isEmpty ?? true),
                       problems.isEmpty {
                        ContentUnavailableView("No problems", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 560, height: 460)
    }

    private func problemGroup(title: String, values: [String]) -> some View {
        Group {
            if !values.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(title) (\(values.count))")
                        .fontWeight(.medium)
                    ForEach(values.prefix(80), id: \.self) { value in
                        Text(value)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if values.count > 80 {
                        Text("\(values.count - 80) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct SettingsSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") { model.showingSettings = false }
                    .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 12) {
                Stepper(value: $model.videoTimeOffsetHours, in: -24...24, step: 0.5) {
                    settingRow(
                        title: "Video time offset",
                        value: "\(String(format: "%+.1f", model.videoTimeOffsetHours)) h"
                    )
                }
                Text("Applied to video capture metadata on the next scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(value: $model.videoHandleSeconds, in: 0...5, step: 0.25) {
                    settingRow(
                        title: "Video export handles",
                        value: "\(String(format: "%.2f", model.videoHandleSeconds)) s"
                    )
                }

                Stepper(value: $model.cacheLimitGB, in: 0.25...20, step: 0.25) {
                    settingRow(
                        title: "Preview cache limit",
                        value: "\(String(format: "%.2f", model.cacheLimitGB)) GB"
                    )
                }
            }

            HStack {
                Button("Reset Timing") { model.videoTimeOffsetHours = 0 }
                Button("Reset Export") { model.videoHandleSeconds = 1 }
                Button("Reset Cache") { model.cacheLimitGB = 5 }
                Spacer()
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func settingRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatePill: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 0.5))
    }
}

private func format(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00.0" }
    let minutes = Int(seconds) / 60
    let remaining = seconds - Double(minutes * 60)
    return "\(minutes):\(String(format: "%04.1f", remaining))"
}

private func byteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
