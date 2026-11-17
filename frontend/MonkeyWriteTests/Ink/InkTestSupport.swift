import PencilKit
import XCTest
@testable import MonkeyWrite

/// A pen stroke through `points` (canvas coordinates).
func makeStroke(_ points: [CGPoint], transform: CGAffineTransform = .identity) -> PKStroke {
    let controlPoints = points.enumerated().map { index, location in
        PKStrokePoint(location: location, timeOffset: Double(index) * 0.01,
                      size: CGSize(width: 4, height: 4), opacity: 1, force: 1,
                      azimuth: 0, altitude: .pi / 2)
    }
    return PKStroke(ink: PKInk(.pen, color: .white),
                    path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()),
                    transform: transform)
}

/// A straight stroke from `from` to `to`.
func makeStroke(from: CGPoint, to: CGPoint) -> PKStroke {
    makeStroke([from, CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), to])
}

/// Hands out values in arrival order. A test releases arrival `n` whenever it
/// chooses (before or after the caller arrives), or answers automatically.
@MainActor
final class Gate<Value> {
    private var waiters: [Int: CheckedContinuation<Value, Never>] = [:]
    private var released: [Int: Value] = [:]
    private(set) var arrivals = 0
    var automatic: ((Int) -> Value)?

    func wait() async -> Value {
        let index = arrivals
        arrivals += 1
        if let automatic { return automatic(index) }
        if let value = released.removeValue(forKey: index) { return value }
        return await withCheckedContinuation { waiters[index] = $0 }
    }

    func release(_ index: Int, _ value: Value) {
        if let waiter = waiters.removeValue(forKey: index) {
            waiter.resume(returning: value)
        } else {
            released[index] = value
        }
    }
}

/// Whole-line text comes from `lineText` (or a gate); group text from `groupText`.
@MainActor
final class FakeStrokeRecognizer: StrokeRecognizing {
    let lineGate = Gate<String?>()
    var groupText: ([UUID]) -> String? = { _ in nil }
    private(set) var preparedDrawings: [PKDrawing] = []
    private(set) var groupRequests: [[UUID]] = []
    var recognizerVersion = "fake-1"

    init(lineText: String?) {
        lineGate.automatic = { _ in lineText }
    }

    /// Whole-line answers wait for `lineGate.release`.
    init() {}

    func prepare(_ drawing: PKDrawing) async -> any StrokeRecognitionSession {
        preparedDrawings.append(drawing)
        return Session(owner: self)
    }

    struct Session: StrokeRecognitionSession {
        let owner: FakeStrokeRecognizer
        func wholeText() async -> String? { await owner.lineGate.wait() }
        func text(forStroke id: UUID) async -> String? { await text(forStrokes: [id]) }
        func text(forStrokes ids: [UUID]) async -> String? {
            owner.groupRequests.append(ids)
            return owner.groupText(ids)
        }
    }
}

@MainActor
func eventually(_ condition: @autoclosure () -> Bool, _ message: String = "Condition not met",
                file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
    }
    XCTFail(message, file: file, line: line)
}
