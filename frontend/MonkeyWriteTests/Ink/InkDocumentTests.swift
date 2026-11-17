import PencilKit
import XCTest
@testable import MonkeyWrite

// Ported from pencilDemo's DebugModelTests (ink document and canvas bridge),
// plus the undoable reset.
@MainActor
final class InkDocumentTests: XCTestCase {
    private func stroke(offset: CGFloat = 0) -> PKStroke {
        makeStroke([CGPoint(x: 20 + offset, y: 20), CGPoint(x: 80 + offset, y: 80)])
    }

    private func drawing(strokes: Int = 1) -> PKDrawing {
        PKDrawing(strokes: (0..<strokes).map { stroke(offset: CGFloat($0) * 100) })
    }

    /// Undo, redo, clear and reset show a detached copy, so compare what is drawn.
    private func ids(_ drawing: PKDrawing) -> [UUID] { drawing.strokes.map(\.id) }

    /// A vertical pixel-eraser path across the test strokes at `x`.
    private func eraserPath(x: CGFloat) -> PKStrokePath {
        let points = (0..<10).map { index in
            PKStrokePoint(location: CGPoint(x: x, y: CGFloat(index) * 40 - 20), timeOffset: Double(index) * 0.01,
                          size: CGSize(width: 20, height: 20), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStrokePath(controlPoints: points, creationDate: Date())
    }

    // MARK: Document

    func testDocumentEditUndoRedoAndClear() {
        var document = InkDocument()
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.clear(), "Clearing an empty drawing is not an edit")
        XCTAssertEqual(document.revision, 0)

        let one = drawing()
        XCTAssertTrue(document.edit(one))
        XCTAssertEqual(document.revision, 1)
        XCTAssertFalse(document.edit(one), "The same drawing is not an edit")
        XCTAssertEqual(document.revision, 1)
        XCTAssertEqual(document.undoHistory.count, 1)

        let two = PKDrawing(strokes: one.strokes + [stroke(offset: 100)])
        document.edit(two)
        XCTAssertTrue(document.clear())
        XCTAssertTrue(document.isEmpty)
        XCTAssertEqual(document.revision, 3)

        XCTAssertTrue(document.undo())
        XCTAssertEqual(ids(document.drawing), ids(two))
        XCTAssertTrue(document.undo())
        XCTAssertEqual(ids(document.drawing), ids(one))
        XCTAssertTrue(document.redo())
        XCTAssertEqual(ids(document.drawing), ids(two))
        XCTAssertEqual(document.revision, 6, "Undo and redo are real changes")

        document.edit(one)
        XCTAssertFalse(document.canRedo, "A new edit discards the redo history")
        while document.undo() {}
        XCTAssertTrue(document.isEmpty)
        XCTAssertFalse(document.undo())
    }

    func testAppChosenDrawingsAreDetachedFromTheCanvasHistory() {
        let one = drawing()
        let two = one.appending(PKDrawing(strokes: [stroke(offset: 100)]))
        var document = InkDocument()
        document.edit(one)
        document.edit(two)
        XCTAssertEqual(document.replacement, 0, "User edits are already on the canvas")

        XCTAssertTrue(document.undo())
        XCTAssertEqual(document.replacement, 1)
        XCTAssertEqual(ids(document.drawing), ids(one))
        XCTAssertNotEqual(document.drawing.dataRepresentation(), one.dataRepresentation(),
                          "Undo shows a new identity, not the older version of the canvas's drawing")
        XCTAssertTrue(document.isCurrent(document.drawing))

        let three = document.drawing.appending(PKDrawing(strokes: [stroke(offset: 200)]))
        XCTAssertTrue(document.edit(three))
        XCTAssertFalse(document.canRedo)
        XCTAssertEqual(document.drawing.strokes.count, 2)
        XCTAssertEqual(document.replacement, 1)

        XCTAssertTrue(document.clear())
        XCTAssertEqual(document.replacement, 2)
        XCTAssertTrue(document.undo())
        XCTAssertTrue(document.redo())
        XCTAssertEqual(document.replacement, 4)
        XCTAssertFalse(document.clear())
        XCTAssertEqual(document.replacement, 4, "Nothing to clear is not a replacement")
    }

    func testUndoKeepsPixelErasedPiecesAndForgetsUndoneErase() {
        // The app has no pixel eraser, but the document must still keep
        // PencilKit's split strokes and masks intact across undo/redo.
        let ink = drawing(strokes: 2)
        let firstErase = ink.erasingPath(eraserPath(x: 60))
        XCTAssertGreaterThan(firstErase.strokes.count, ink.strokes.count, "The eraser splits strokes")
        var document = InkDocument()
        document.edit(ink)
        document.edit(firstErase)

        XCTAssertTrue(document.undo())
        XCTAssertEqual(ids(document.drawing), ids(ink), "The undone erase is gone")
        let secondErase = document.drawing.erasingPath(eraserPath(x: 160))
        let expected = ink.erasingPath(eraserPath(x: 160))
        document.edit(secondErase)
        XCTAssertEqual(document.drawing.strokes.count, expected.strokes.count)

        XCTAssertTrue(document.undo())
        XCTAssertTrue(document.undo())
        XCTAssertTrue(document.redo())
        XCTAssertEqual(ids(document.drawing), ids(ink))
        XCTAssertTrue(document.redo())
        XCTAssertEqual(document.drawing.strokes.count, expected.strokes.count)
        XCTAssertEqual(document.drawing.strokes.map { $0.mask != nil }, expected.strokes.map { $0.mask != nil },
                       "Redo keeps the erased pieces' masks")
    }

    func testDocumentHistoryLimit() {
        XCTAssertEqual(InkDocument.historyLimit, 100)
        var document = InkDocument()
        for _ in 0..<(InkDocument.historyLimit + 5) {
            document.edit(drawing())
        }
        XCTAssertEqual(document.undoHistory.count, InkDocument.historyLimit)
    }

    func testDocumentTreatsEveryEmptyDrawingAsTheSame() {
        var erased = drawing()
        erased.strokes = []
        XCTAssertTrue(InkDocument.isSame(erased, PKDrawing()))
        XCTAssertFalse(InkDocument.isSame(drawing(), PKDrawing()))
        var document = InkDocument()
        XCTAssertFalse(document.edit(erased))
        XCTAssertFalse(document.canUndo)
    }

    // MARK: Reset

    func testHardResetForgetsEverything() {
        var document = InkDocument()
        document.edit(drawing())
        document.edit(drawing(strokes: 2))
        document.undo()
        let replacement = document.replacement
        document.reset()
        XCTAssertTrue(document.isEmpty)
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.canRedo)
        XCTAssertEqual(document.replacement, replacement + 1)
        document.reset()
        XCTAssertEqual(document.replacement, replacement + 2, "Even an empty reset makes the canvas start over")
    }

    func testUndoableResetRestoresDrawingAndHistory() {
        var document = InkDocument()
        let one = drawing()
        let two = drawing(strokes: 2)
        document.edit(one)
        document.edit(two)
        XCTAssertTrue(document.resetUndoably())
        XCTAssertTrue(document.isEmpty)
        XCTAssertTrue(document.isShowingUndoableReset)
        XCTAssertTrue(document.canUndo)

        XCTAssertTrue(document.undo())
        XCTAssertEqual(ids(document.drawing), ids(two))
        XCTAssertFalse(document.isShowingUndoableReset)
        XCTAssertTrue(document.undo(), "History from before the reset is intact")
        XCTAssertEqual(ids(document.drawing), ids(one))

        // Redo back onto the reset paper: it is still an undoable reset.
        XCTAssertTrue(document.redo())
        XCTAssertTrue(document.redo())
        XCTAssertTrue(document.isEmpty)
        XCTAssertTrue(document.isShowingUndoableReset)
        var empty = InkDocument()
        XCTAssertFalse(empty.resetUndoably(), "Nothing to reset")
    }

    func testFirstStrokeAfterUndoableResetDropsEarlierHistory() {
        var document = InkDocument()
        document.edit(drawing())
        document.edit(drawing(strokes: 2))
        document.resetUndoably()

        let fresh = PKDrawing(strokes: [stroke(offset: 500)])
        XCTAssertTrue(document.edit(fresh))
        XCTAssertFalse(document.isShowingUndoableReset)
        XCTAssertEqual(document.undoHistory.count, 1, "Only the empty reset paper remains to undo to")
        XCTAssertTrue(document.undo())
        XCTAssertTrue(document.isEmpty)
        XCTAssertFalse(document.undo(), "The pre-reset drawing is gone")
        XCTAssertTrue(document.redo())
        XCTAssertEqual(ids(document.drawing), ids(fresh))
    }

    func testEditAfterUndoingResetForgetsTheReset() {
        var document = InkDocument()
        let one = drawing()
        document.edit(one)
        document.resetUndoably()
        document.undo()
        let more = PKDrawing(strokes: document.drawing.strokes + [stroke(offset: 300)])
        XCTAssertTrue(document.edit(more))
        XCTAssertNil(document.resetDepth)
        XCTAssertFalse(document.canRedo)
        XCTAssertTrue(document.undo())
        XCTAssertEqual(ids(document.drawing), ids(one))
        XCTAssertTrue(document.undo())
        XCTAssertTrue(document.isEmpty)
    }

    func testClearOnResetPaperIsNotAnEdit() {
        var document = InkDocument()
        document.edit(drawing())
        document.resetUndoably()
        XCTAssertFalse(document.clear())
        XCTAssertTrue(document.isShowingUndoableReset, "A no-op clear keeps the reset undoable")
    }

    // MARK: Canvas bridge

    private func makeModel() -> InkCanvasModel { InkCanvasModel(visibleLines: 5) }

    func testProgrammaticCanvasCallbackIsNotAnEdit() {
        let model = makeModel()
        model.drawingChanged(drawing())
        let canvas = PKCanvasView()
        canvas.drawing = model.drawing
        let coordinator = PaperCanvas.Coordinator(model: model)
        coordinator.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(model.revision, 1)
        canvas.drawing = PKDrawing()
        coordinator.canvasViewDrawingDidChange(canvas)
        XCTAssertEqual(model.revision, 2)
    }

    func testUndoUpdatesCanvasWithoutCreatingAnotherEdit() {
        let model = makeModel()
        model.drawingChanged(drawing())
        let canvas = PaperCanvas.CanvasView()
        let view = PaperCanvas(model: model)
        view.updateCanvas(canvas)
        model.undo()
        view.updateCanvas(canvas)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
        PaperCanvas.Coordinator(model: model).canvasViewDrawingDidChange(canvas)
        XCTAssertTrue(model.canRedo)
        XCTAssertEqual(model.revision, 2)
        XCTAssertFalse(canvas.undoManager?.isUndoRegistrationEnabled ?? true)
        model.redo()
        view.updateCanvas(canvas)
        XCTAssertTrue(model.document.isCurrent(canvas.drawing))
    }

    func testCanvasIsOnlyOverwrittenWhenTheAppReplacesTheDrawing() {
        let model = makeModel()
        let one = drawing()
        model.drawingChanged(one)
        let canvas = PaperCanvas.CanvasView()
        let view = PaperCanvas(model: model)
        view.updateCanvas(canvas)
        XCTAssertTrue(model.document.isCurrent(canvas.drawing))

        // The canvas moved on (say, mid-erase) before reporting it. An update
        // must not write the model's older version of the drawing back.
        let newer = canvas.drawing.appending(PKDrawing(strokes: [stroke(offset: 100)]))
        canvas.drawing = newer
        view.updateCanvas(canvas)
        XCTAssertEqual(canvas.drawing.dataRepresentation(), newer.dataRepresentation())

        PaperCanvas.Coordinator(model: model).canvasViewDrawingDidChange(canvas)
        model.undo()
        view.updateCanvas(canvas)
        XCTAssertEqual(ids(canvas.drawing), ids(one))
        XCTAssertTrue(model.document.isCurrent(canvas.drawing))
        model.resetUndoably()
        view.updateCanvas(canvas)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)
    }

    func testCanvasConfiguration() {
        let model = makeModel()
        let canvas = PaperCanvas.CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 520))
        let view = PaperCanvas(model: model)
        model.viewportDidChange(canvas.bounds.size)
        view.updateCanvas(canvas)
        XCTAssertTrue(canvas.tool is PKInkingTool)
        XCTAssertEqual(canvas.drawingPolicy, model.inputPolicy.drawingPolicy)
        XCTAssertEqual(canvas.panGestureRecognizer.minimumNumberOfTouches, model.inputPolicy.scrollTouches)
        XCTAssertEqual(canvas.contentSize.width, 800)
        XCTAssertEqual(canvas.contentSize.height, model.layout!.contentHeight(lineCount: 7), accuracy: 0.001)
        model.toggleEraser()
        view.updateCanvas(canvas)
        XCTAssertEqual((canvas.tool as? PKEraserTool)?.eraserType, .vector)
    }

    func testInputPolicy() {
        #if targetEnvironment(simulator)
        XCTAssertEqual(PaperInputPolicy.policy(fingerWriting: false), PaperInputPolicy(drawingPolicy: .anyInput, scrollTouches: 2))
        #else
        XCTAssertEqual(PaperInputPolicy.policy(fingerWriting: false), PaperInputPolicy(drawingPolicy: .pencilOnly, scrollTouches: 1))
        #endif
        XCTAssertEqual(PaperInputPolicy.policy(fingerWriting: true), PaperInputPolicy(drawingPolicy: .anyInput, scrollTouches: 2))
    }

    // MARK: Canvas model

    func testLayoutIsFixedForTheTestAndRecomputedForTheNext() {
        let model = InkCanvasModel(visibleLines: 5)
        var changes: [InkCanvasModel.Change] = []
        model.onChange = { changes.append($0) }
        model.viewportDidChange(CGSize(width: 800, height: 512))
        let first = model.layout
        XCTAssertEqual(first?.lineHeight ?? 0, (512 - PaperLayout.defaultTopInset) / 5, accuracy: 0.001)
        model.viewportDidChange(CGSize(width: 800, height: 300))
        XCTAssertEqual(model.layout, first, "A resize inside a test keeps the lines")

        model.drawingChanged(drawing())
        model.startNewTest(visibleLines: 4)
        XCTAssertTrue(model.drawing.strokes.isEmpty)
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(model.layout?.lineHeight ?? 0, (300 - PaperLayout.defaultTopInset) / 4, accuracy: 0.001)
        XCTAssertEqual(changes, [.edit, .newTest])
    }

    func testPaperGrowsBelowTheLowestLine() {
        let model = InkCanvasModel(visibleLines: 3)
        model.viewportDidChange(CGSize(width: 800, height: 312))
        let layout = model.layout!
        XCTAssertEqual(model.lineCount, 5)
        let y = layout.band(ofLine: 6).lowerBound + layout.lineHeight / 2
        model.drawingChanged(PKDrawing(strokes: [makeStroke(from: CGPoint(x: 10, y: y), to: CGPoint(x: 200, y: y))]))
        XCTAssertEqual(model.highestUsedLine, 6)
        XCTAssertEqual(model.lineOfLastStroke, 6)
        XCTAssertEqual(model.lineCount, 6 + 3 + 1)
    }
}
