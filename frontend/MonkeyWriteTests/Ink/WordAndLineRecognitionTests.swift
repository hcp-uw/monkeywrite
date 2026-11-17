import PencilKit
import XCTest
@testable import MonkeyWrite

final class WordGrouperTests: XCTestCase {
    private func extent(_ minX: CGFloat, _ maxX: CGFloat) -> WordGrouper.Extent {
        WordGrouper.Extent(id: UUID(), minX: minX, maxX: maxX)
    }

    func testGapsSplitWords() {
        // lineHeight 100 -> threshold 45: gaps 20 (same word), 100 and 60 (new words).
        let a = extent(0, 40), b = extent(60, 100), c = extent(200, 260), d = extent(320, 360)
        let groups = WordGrouper.group(extents: [a, b, c, d], lineHeight: 100)
        XCTAssertEqual(groups, [[a.id, b.id], [c.id], [d.id]])
    }

    func testOverlappingStrokesAndDrawingOrder() {
        // A "t" crossbar drawn after the next letter, overlapping both.
        let t = extent(0, 20), h = extent(25, 60), bar = extent(-10, 30)
        let word2 = extent(150, 200)
        let groups = WordGrouper.group(extents: [t, h, bar, word2], lineHeight: 100)
        XCTAssertEqual(groups, [[t.id, h.id, bar.id], [word2.id]], "Groups left to right, IDs in drawing order")
    }

    func testSingleWordAndEmpty() {
        let strokes = (0..<5).map { extent(CGFloat($0) * 30, CGFloat($0) * 30 + 25) }
        XCTAssertEqual(WordGrouper.group(extents: strokes, lineHeight: 100), [strokes.map(\.id)])
        XCTAssertEqual(WordGrouper.group(extents: [], lineHeight: 100), [])
    }

    func testRealStrokes() {
        let one = makeStroke(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 40, y: 90))
        let two = makeStroke(from: CGPoint(x: 150, y: 50), to: CGPoint(x: 190, y: 90))
        XCTAssertEqual(WordGrouper.group([two, one], lineHeight: 100), [[one.id], [two.id]])
    }
}

@MainActor
final class LineRecognizerTests: XCTestCase {
    /// Three strokes: two touching (one word), one far right (another word).
    private let a = makeStroke(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 40, y: 90))
    private let b = makeStroke(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 90, y: 90))
    private let c = makeStroke(from: CGPoint(x: 300, y: 50), to: CGPoint(x: 340, y: 90))

    func testWordCountMatchesGroups() async throws {
        let fake = FakeStrokeRecognizer(lineText: "Hello, world")
        let line = try await LineRecognizer(recognizer: fake)
            .recognize(lineIndex: 2, strokes: [a, b, c], lineHeight: 100)
        XCTAssertEqual(line, WrittenLine(index: 2, words: [
            WrittenWord(text: "Hello,", strokeIDs: [a.id, b.id]),
            WrittenWord(text: "world", strokeIDs: [c.id]),
        ]))
        XCTAssertEqual(fake.preparedDrawings.first?.strokes.map(\.id), [a.id, b.id, c.id])
        XCTAssertTrue(fake.groupRequests.isEmpty, "No per-group work when counts agree")
    }

    func testMismatchFallsBackToPerGroupText() async throws {
        // The line reads as three words but the gaps make two groups; the
        // first group reads as two words.
        let fake = FakeStrokeRecognizer(lineText: "to be good")
        fake.groupText = { [a, c] ids in ids.contains(a.id) ? "to be" : ids == [c.id] ? "good" : nil }
        let line = try await LineRecognizer(recognizer: fake)
            .recognize(lineIndex: 0, strokes: [a, b, c], lineHeight: 100)
        XCTAssertEqual(line.words, [
            WrittenWord(text: "to", strokeIDs: [a.id, b.id]),
            WrittenWord(text: "be", strokeIDs: [a.id, b.id]),
            WrittenWord(text: "good", strokeIDs: [c.id]),
        ])
        XCTAssertEqual(fake.groupRequests, [[a.id, b.id], [c.id]])
    }

    func testMismatchUsesGroupWordsWhenCountsStillDisagree() async throws {
        // The whole line merged everything into one word; groups read two
        // words and one is empty (a stray mark), which is dropped.
        let d = makeStroke(from: CGPoint(x: 600, y: 50), to: CGPoint(x: 602, y: 52))
        let fake = FakeStrokeRecognizer(lineText: "cathat")
        fake.groupText = { [c, d] ids in ids == [c.id] ? "hat" : ids == [d.id] ? "" : "cat" }
        let line = try await LineRecognizer(recognizer: fake)
            .recognize(lineIndex: 1, strokes: [a, b, c, d], lineHeight: 100)
        XCTAssertEqual(line.words.map(\.text), ["cat", "hat"])
        XCTAssertEqual(line.words.map(\.strokeIDs), [[a.id, b.id], [c.id]])
    }

    func testNoGroupTextKeepsLineWordsWithoutStrokes() {
        XCTAssertEqual(LineRecognizer.reconcile(lineWords: ["a", "b", "c"], groupWords: []),
                       [WrittenWord(text: "a", strokeIDs: []), WrittenWord(text: "b", strokeIDs: []),
                        WrittenWord(text: "c", strokeIDs: [])])
    }

    func testEmptyLine() async throws {
        let fake = FakeStrokeRecognizer(lineText: "x")
        let line = try await LineRecognizer(recognizer: fake).recognize(lineIndex: 4, strokes: [], lineHeight: 100)
        XCTAssertEqual(line, WrittenLine(index: 4, words: []))
        XCTAssertTrue(fake.preparedDrawings.isEmpty)
    }

    func testCancellationStopsBeforePublishingOrPerGroupWork() async {
        let fake = FakeStrokeRecognizer()
        let recognizer = LineRecognizer(recognizer: fake)
        let strokes = [a, b, c]
        let task = Task { try await recognizer.recognize(lineIndex: 0, strokes: strokes, lineHeight: 100) }
        await eventually(fake.lineGate.arrivals == 1)
        task.cancel()
        fake.lineGate.release(0, "one two three")  // a mismatch would need per-group work
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(fake.groupRequests.isEmpty)
    }
}
