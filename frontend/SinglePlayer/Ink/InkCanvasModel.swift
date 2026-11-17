import Combine
import PencilKit
import SwiftUI

/// The two tools of the paper. There is deliberately no pixel eraser: erasing
/// whole strokes keeps stroke IDs (and so words) intact.
enum CanvasTool: String, CaseIterable, Identifiable, Sendable {
    case pen
    case eraser

    /// Ink is light on the dark paper (see `PaperCanvas` for why PencilKit
    /// does not invert it).
    static let inkWidth: CGFloat = 3.5
    static var inkColor: UIColor { UIColor(Theme.text) }

    var id: Self { self }
    var title: String { self == .pen ? "Pen" : "Eraser" }
    var tool: PKTool {
        switch self {
        case .pen: PKInkingTool(.pen, color: Self.inkColor, width: Self.inkWidth)
        case .eraser: PKEraserTool(.vector)
        }
    }

    func matches(_ tool: PKTool) -> Bool {
        switch self {
        case .pen: tool is PKInkingTool
        case .eraser: (tool as? PKEraserTool)?.eraserType == .vector
        }
    }
}

/// How touches reach the paper.
struct PaperInputPolicy: Equatable {
    var drawingPolicy: PKCanvasViewDrawingPolicy
    /// Fingers needed to scroll the paper.
    var scrollTouches: Int

    /// - Device, default: only Apple Pencil draws; one finger scrolls.
    /// - Device, finger writing: any touch draws; two fingers scroll.
    /// - Simulator: always any input (the mouse is the "pencil"), with
    ///   two-touch scrolling so a mouse drag never scrolls instead of drawing.
    ///   Trackpad and scroll-wheel scrolling still work: they arrive as scroll
    ///   events, which do not count touches.
    static func policy(fingerWriting: Bool) -> PaperInputPolicy {
        #if targetEnvironment(simulator)
        PaperInputPolicy(drawingPolicy: .anyInput, scrollTouches: 2)
        #else
        fingerWriting
            ? PaperInputPolicy(drawingPolicy: .anyInput, scrollTouches: 2)
            : PaperInputPolicy(drawingPolicy: .pencilOnly, scrollTouches: 1)
        #endif
    }
}

/// Owns everything the paper shows: the ink document (with the app's own
/// undo/redo), the tool, the fixed paper layout and which line each stroke is
/// on. The round model owns one of these, drives it (undo, redo, reset,
/// new test) and listens to `onChange` to re-analyze.
@MainActor
final class InkCanvasModel: ObservableObject {
    enum Change: Equatable {
        /// The user drew or erased on the canvas.
        case edit
        case undo, redo, clear
        /// `resetUndoably()`.
        case reset
        /// `startNewTest(visibleLines:)`: empty paper, no history, new layout.
        case newTest
    }

    @Published private(set) var document = InkDocument()
    @Published var tool: CanvasTool = .pen
    @Published var fingerWriting: Bool
    /// False freezes the ink (for example when the test is complete): the
    /// paper still scrolls but no longer draws or erases.
    @Published var isWritingEnabled = true
    /// Back to the pen when an eraser use that erased something ends.
    var autoSwitchToPen = true
    /// Nil until the canvas has been laid out once for this test.
    @Published private(set) var layout: PaperLayout?
    /// The paper line of every stroke; empty while `layout` is nil.
    @Published private(set) var lineAssignments: [UUID: Int] = [:]
    /// Lines visible at once, fixed for the current test.
    private(set) var visibleLines: Int
    /// The latest laid-out paper height, kept to lay out the next test at once.
    private(set) var viewportHeight: CGFloat?
    /// The document revision when the current eraser use began.
    private var eraserStartRevision: Int?

    /// Called after every document change, with what caused it.
    var onChange: ((Change) -> Void)?

    init(visibleLines: Int = SinglePlayerSettings().visibleLines, fingerWriting: Bool = false) {
        self.visibleLines = Self.clamped(visibleLines)
        self.fingerWriting = fingerWriting
    }

    var drawing: PKDrawing { document.drawing }
    var revision: Int { document.revision }
    var canUndo: Bool { document.canUndo }
    var canRedo: Bool { document.canRedo }
    var inputPolicy: PaperInputPolicy { .policy(fingerWriting: fingerWriting) }

    var highestUsedLine: Int? { lineAssignments.values.max() }
    /// The line of the most recent stroke (strokes are in drawing order).
    var lineOfLastStroke: Int? { drawing.strokes.last.flatMap { lineAssignments[$0.id] } }
    var lineCount: Int { PaperLayout.lineCount(visibleLines: visibleLines, highestUsedLine: highestUsedLine) }

    // MARK: Canvas input

    /// A drawing reported by the canvas (user stroke or erase).
    func drawingChanged(_ drawing: PKDrawing) {
        guard document.edit(drawing) else { return }
        documentChanged(.edit)
    }

    /// The laid-out paper size. The first size of a test fixes its layout;
    /// later sizes are only remembered for the next test.
    func viewportDidChange(_ size: CGSize) {
        guard size.height > 0 else { return }
        viewportHeight = size.height
        if layout == nil { setLayout(.fitting(height: size.height, visibleLines: visibleLines)) }
    }

    func toggleEraser() {
        tool = tool == .pen ? .eraser : .pen
    }

    /// The pencil (or finger) touched down with the current tool.
    func toolUseBegan() {
        eraserStartRevision = tool == .eraser ? document.revision : nil
    }

    /// The pencil lifted. One eraser drag may erase several strokes, so the
    /// switch back to the pen waits for the lift, and an eraser use that
    /// erased nothing keeps the eraser.
    func toolUseEnded() {
        defer { eraserStartRevision = nil }
        guard autoSwitchToPen, tool == .eraser, let start = eraserStartRevision,
              document.revision != start else { return }
        tool = .pen
    }

    // MARK: Commands

    func undo() { if document.undo() { documentChanged(.undo) } }
    func redo() { if document.redo() { documentChanged(.redo) } }
    func clear() { if document.clear() { documentChanged(.clear) } }

    /// Empties the paper; undoable until the next stroke (see `InkDocument`).
    /// Keeps the layout. Returns false when the paper was already empty.
    @discardableResult
    func resetUndoably() -> Bool {
        guard document.resetUndoably() else { return false }
        documentChanged(.reset)
        return true
    }

    /// A fresh test: empty paper, no history, pen, and a layout recomputed for
    /// `visibleLines` from the last known paper height (or on the next layout).
    func startNewTest(visibleLines: Int) {
        self.visibleLines = Self.clamped(visibleLines)
        document.reset()
        tool = .pen
        layout = nil
        if let viewportHeight {
            setLayout(.fitting(height: viewportHeight, visibleLines: self.visibleLines))
        } else {
            lineAssignments = [:]
        }
        onChange?(.newTest)
    }

    // MARK: Private

    private static func clamped(_ lines: Int) -> Int {
        min(SinglePlayerSettings.visibleLineRange.upperBound,
            max(SinglePlayerSettings.visibleLineRange.lowerBound, lines))
    }

    private func setLayout(_ newLayout: PaperLayout) {
        layout = newLayout
        reassignLines()
    }

    private func documentChanged(_ change: Change) {
        reassignLines()
        onChange?(change)
    }

    private func reassignLines() {
        guard let layout else { lineAssignments = [:]; return }
        lineAssignments = LineAssigner.assign(drawing.strokes, layout: layout)
    }
}
