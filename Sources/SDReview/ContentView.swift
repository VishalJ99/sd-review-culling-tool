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
                if item.kind == .photo {
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
                Text(warning)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text("\(session?.undecidedCount ?? 0) undecided")
                .foregroundStyle(.secondary)
            StateBadge(decision: item?.decision ?? .undecided, crop: item?.crop != nil, segments: item?.segments.count ?? 0)
            Button("Export") { model.prepareExport() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!model.canExport)
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
                handles(rect: rect)
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

    private func handles(rect: CGRect) -> some View {
        ZStack {
            ForEach(Array(handlePoints(rect: rect).enumerated()), id: \.offset) { _, point in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 7, height: 7)
                    .position(point)
            }
        }
    }

    private func handlePoints(rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
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
                    Capsule().fill(Color.secondary.opacity(0.16))
                    ForEach(item.segments) { segment in
                        let rect = segmentRect(segment.startSeconds, segment.endSeconds, duration: model.videoDurationSeconds, width: proxy.size.width)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(segment.id == model.selectedSegmentID ? Color.teal : Color.teal.opacity(0.65))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
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

            if let message = model.exportMessage {
                Text(message)
                    .foregroundStyle(message.hasPrefix("Exported") ? .green : .red)
                    .lineLimit(3)
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
