import Foundation

public final class ReviewSession {
    public private(set) var document: SessionDocument
    public private(set) var currentItemID: String?
    private let undoLimit: Int

    public init(document: SessionDocument, undoLimit: Int = 200) {
        self.document = document
        self.currentItemID = document.lastItemID ?? document.items.first?.id
        self.undoLimit = undoLimit
    }

    public var filter: TimelineFilter {
        get { document.filter }
        set {
            document.filter = newValue
            if let currentItem, newValue.includes(currentItem.decision) {
                return
            }
            currentItemID = filteredItems.first?.id
            document.lastItemID = currentItemID
        }
    }

    public var filteredItems: [MediaItem] {
        document.items.filter { document.filter.includes($0.decision) }
    }

    public var currentItem: MediaItem? {
        guard let currentItemID else { return filteredItems.first }
        return document.items.first { $0.id == currentItemID }
    }

    public var currentPosition: Int {
        guard let currentItemID,
              let index = filteredItems.firstIndex(where: { $0.id == currentItemID }) else {
            return filteredItems.isEmpty ? 0 : 1
        }
        return index + 1
    }

    public var undecidedCount: Int {
        document.items.filter { $0.decision == .undecided }.count
    }

    public var keepCount: Int {
        document.items.filter { $0.decision == .keep }.count
    }

    public var rejectCount: Int {
        document.items.filter { $0.decision == .reject }.count
    }

    public func moveNext() {
        move(delta: 1)
    }

    public func movePrevious() {
        move(delta: -1)
    }

    public func jumpToItem(id: String) {
        guard document.items.contains(where: { $0.id == id }) else { return }
        currentItemID = id
        document.lastItemID = id
    }

    public func cycleFilter() {
        perform {
            filter = filter.next()
        }
    }

    public func markKeepOrToggle() {
        setDecisionOrToggle(.keep)
    }

    public func markRejectOrToggle() {
        setDecisionOrToggle(.reject)
    }

    public func setCrop(_ crop: NormalizedCropRect?) {
        guard let id = currentItemID else { return }
        perform {
            updateItem(id: id) { item in
                item.crop = crop
                if crop != nil {
                    item.decision = .keep
                }
            }
        }
    }

    public func addSegment(start: Double, end: Double) {
        guard let id = currentItemID else { return }
        perform {
            updateItem(id: id) { item in
                item.segments.append(VideoSegment(startSeconds: start, endSeconds: end))
                item.segments.sort { $0.startSeconds < $1.startSeconds }
                item.decision = .keep
            }
        }
    }

    public func replaceSegment(segmentID: UUID, start: Double? = nil, end: Double? = nil) {
        guard let id = currentItemID else { return }
        perform {
            updateItem(id: id) { item in
                guard let index = item.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                let existing = item.segments[index]
                item.segments[index] = VideoSegment(
                    id: existing.id,
                    startSeconds: start ?? existing.startSeconds,
                    endSeconds: end ?? existing.endSeconds
                )
                item.segments.sort { $0.startSeconds < $1.startSeconds }
                item.decision = .keep
            }
        }
    }

    public func removeSegment(segmentID: UUID) {
        guard let id = currentItemID else { return }
        perform {
            updateItem(id: id) { item in
                item.segments.removeAll { $0.id == segmentID }
            }
        }
    }

    public func undo() {
        guard let previous = document.undoStack.popLast() else { return }
        document.redoStack.append(snapshot())
        apply(previous)
    }

    public func redo() {
        guard let next = document.redoStack.popLast() else { return }
        document.undoStack.append(snapshot())
        apply(next)
    }

    private func setDecisionOrToggle(_ decision: ReviewDecision) {
        guard let id = currentItemID,
              let item = document.items.first(where: { $0.id == id }) else { return }
        let wasUndecided = item.decision == .undecided
        let nextDecision: ReviewDecision = item.decision == decision ? .undecided : decision

        perform {
            updateItem(id: id) { $0.decision = nextDecision }
            if wasUndecided {
                move(delta: 1)
            }
        }
    }

    private func move(delta: Int) {
        let items = filteredItems
        guard !items.isEmpty else {
            currentItemID = nil
            document.lastItemID = nil
            return
        }

        let currentIndex = currentItemID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), items.count - 1)
        currentItemID = items[nextIndex].id
        document.lastItemID = currentItemID
    }

    private func perform(_ change: () -> Void) {
        let before = snapshot()
        change()
        guard before != snapshot() else { return }
        document.undoStack.append(before)
        if document.undoStack.count > undoLimit {
            document.undoStack.removeFirst(document.undoStack.count - undoLimit)
        }
        document.redoStack.removeAll()
    }

    private func updateItem(id: String, mutate: (inout MediaItem) -> Void) {
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&document.items[index])
        document.lastItemID = currentItemID
    }

    private func snapshot() -> ReviewSnapshot {
        ReviewSnapshot(lastItemID: document.lastItemID, filter: document.filter, items: document.items)
    }

    private func apply(_ snapshot: ReviewSnapshot) {
        document.items = snapshot.items
        document.filter = snapshot.filter
        document.lastItemID = snapshot.lastItemID
        currentItemID = snapshot.lastItemID ?? snapshot.items.first?.id
    }
}
