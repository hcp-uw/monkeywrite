import PencilKit
import XCTest
@testable import MonkeyWrite

@MainActor
final class InkCanvasModelTests: XCTestCase {
    private func model(with strokes: Int) -> InkCanvasModel {
        let model = InkCanvasModel()
        model.viewportDidChange(CGSize(width: 1000, height: 600))
        let drawn = (0..<strokes).map { i in
            makeStroke(from: CGPoint(x: 40 + i * 100, y: 60), to: CGPoint(x: 100 + i * 100, y: 80))
        }
        model.drawingChanged(PKDrawing(strokes: drawn))
        return model
    }

    private func erase(_ count: Int, in model: InkCanvasModel) {
        var drawing = model.drawing
        drawing.strokes.removeFirst(count)
        model.drawingChanged(drawing)
    }

    func testLiftingAfterErasingSwitchesBackToThePen() {
        let model = model(with: 3)
        model.tool = .eraser
        model.toolUseBegan()
        erase(1, in: model)
        XCTAssertEqual(model.tool, .eraser, "Not mid-drag")
        erase(1, in: model)
        XCTAssertEqual(model.tool, .eraser, "One drag may erase several strokes")
        model.toolUseEnded()
        XCTAssertEqual(model.tool, .pen)
    }

    func testAnEraserUseThatErasedNothingKeepsTheEraser() {
        let model = model(with: 2)
        model.tool = .eraser
        model.toolUseBegan()
        model.toolUseEnded()
        XCTAssertEqual(model.tool, .eraser)
    }

    func testNoSwitchWhenTheSettingIsOff() {
        let model = model(with: 2)
        model.autoSwitchToPen = false
        model.tool = .eraser
        model.toolUseBegan()
        erase(1, in: model)
        model.toolUseEnded()
        XCTAssertEqual(model.tool, .eraser)
    }

    func testPenUseAndDoubleTapAreUnaffected() {
        let model = model(with: 1)
        model.toolUseBegan()
        model.drawingChanged(model.drawing.appending(PKDrawing(strokes: [makeStroke(from: CGPoint(x: 300, y: 60), to: CGPoint(x: 360, y: 80))])))
        model.toolUseEnded()
        XCTAssertEqual(model.tool, .pen)

        // Double-tap to the eraser mid-use (the pen's use began with the pen):
        // lifting does not switch back.
        model.toolUseBegan()
        model.toggleEraser()
        erase(1, in: model)
        model.toolUseEnded()
        XCTAssertEqual(model.tool, .eraser)
        model.toggleEraser()
        XCTAssertEqual(model.tool, .pen)
    }
}
