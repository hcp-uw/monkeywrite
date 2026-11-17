import PencilKit

/// The retained ink: the drawing, its revision, and the app's own undo/redo
/// history. Every real change produces a new revision; a drawing that is the
/// "same" as the current one (see `isSame`) is never an edit.
///
/// The history lives here rather than in PencilKit's undo manager so Clear and
/// Reset are undoable too, and so the canvas cannot keep a second, diverging
/// history.
///
/// PKDrawing is a mergeable (CRDT) value: every drawing derived from another
/// keeps its identity and a version vector, and merging an older version with
/// a newer one brings back strokes and pixel erasures the older one lacked.
/// So a drawing the app puts on the canvas itself (undo, redo, clear, reset)
/// gets a fresh identity, and `replacement` tells the canvas to start over
/// instead of combining it with what PencilKit still holds from before.
///
/// Two kinds of reset:
/// - `reset()` starts over for good: empty drawing, no history.
/// - `resetUndoably()` empties the paper but can be undone until the next
///   edit. Undo brings back the drawing and its whole history; the first
///   stroke or erase on the reset paper forgets everything before the reset
///   (the new stroke itself can still be undone back to the empty paper).
struct InkDocument {
    static let historyLimit = 100

    private(set) var drawing = PKDrawing()
    private(set) var revision = 0
    /// Counts drawings the app chose rather than the canvas reporting them
    /// (undo, redo, clear, reset). The canvas must replace its contents when
    /// it changes.
    private(set) var replacement = 0
    /// Drawings before (undo) and after (redo) the current one.
    private(set) var undoHistory: [PKDrawing] = []
    private(set) var redoHistory: [PKDrawing] = []
    /// `undoHistory.count` while the document shows an undoable reset's empty
    /// paper. Undo/redo move off and back onto that state; the next edit made
    /// on it drops all earlier history, an edit made after undoing the reset
    /// forgets the reset instead.
    private(set) var resetDepth: Int?

    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var isEmpty: Bool { drawing.strokes.isEmpty }
    /// True while the empty paper of an undoable reset is shown.
    var isShowingUndoableReset: Bool { resetDepth == undoHistory.count }

    /// The one "same drawing" rule. Two empty drawings can serialize
    /// differently, so they compare equal directly.
    static func isSame(_ lhs: PKDrawing, _ rhs: PKDrawing) -> Bool {
        if lhs.strokes.isEmpty && rhs.strokes.isEmpty { return true }
        return lhs.dataRepresentation() == rhs.dataRepresentation()
    }

    /// True when `canvasDrawing` already matches the document, for example when
    /// the canvas reports back a drawing the app just assigned to it.
    func isCurrent(_ canvasDrawing: PKDrawing) -> Bool {
        Self.isSame(canvasDrawing, drawing)
    }

    /// A user stroke or erase, already on the canvas. Returns false, and
    /// records nothing, when the drawing does not really differ.
    @discardableResult
    mutating func edit(_ newDrawing: PKDrawing) -> Bool {
        guard !isCurrent(newDrawing) else { return false }
        commitReset()
        record()
        show(newDrawing)
        return true
    }

    /// Clearing is an undoable edit to an empty drawing that the canvas must show.
    @discardableResult
    mutating func clear() -> Bool {
        guard !isEmpty else { return false }
        commitReset()
        record()
        replace(with: PKDrawing())
        return true
    }

    /// Starts over for good: empty drawing, no undo or redo. Always tells the
    /// canvas to replace its contents, even when the paper was already empty.
    mutating func reset() {
        undoHistory = []
        redoHistory = []
        resetDepth = nil
        replace(with: PKDrawing())
    }

    /// Empties the paper so that one Undo brings back the drawing and its
    /// history, until the next edit (see the type comment). Returns false and
    /// changes nothing when the paper is already empty.
    @discardableResult
    mutating func resetUndoably() -> Bool {
        guard !isEmpty else { return false }
        commitReset()
        record()
        replace(with: PKDrawing())
        resetDepth = undoHistory.count
        return true
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let previous = undoHistory.popLast() else { return false }
        redoHistory.append(drawing)
        replace(with: previous)
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let next = redoHistory.popLast() else { return false }
        undoHistory.append(drawing)
        replace(with: next)
        return true
    }

    /// A drawing with the same strokes (masks included) but a new identity and
    /// no version history, so nothing can merge older or newer state into it.
    static func detached(_ drawing: PKDrawing) -> PKDrawing {
        PKDrawing(strokes: drawing.strokes)
    }

    /// Before a new change: an edit on the reset paper makes the reset final,
    /// an edit anywhere else (the reset was undone) forgets the reset.
    private mutating func commitReset() {
        guard let depth = resetDepth else { return }
        if undoHistory.count >= depth { undoHistory = [] }
        resetDepth = nil
    }

    /// Saves the current drawing for undo before a new edit.
    private mutating func record() {
        undoHistory.append(drawing)
        if undoHistory.count > Self.historyLimit { undoHistory.removeFirst(undoHistory.count - Self.historyLimit) }
        redoHistory = []
    }

    /// Shows a drawing the app chose; the canvas has to be told about it.
    private mutating func replace(with newDrawing: PKDrawing) {
        show(Self.detached(newDrawing))
        replacement += 1
    }

    private mutating func show(_ newDrawing: PKDrawing) {
        drawing = newDrawing
        revision += 1
    }
}
