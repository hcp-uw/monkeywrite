import XCTest
@testable import MonkeyWrite

final class PassageLayoutTests: XCTestCase {
    func testWrappingCoversAllWordsInOrder() {
        let words = BundledPassages.all[0].words
        let lines = PassageLayout.lines(words: words, maxWidth: 400)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines.first?.lowerBound, 0)
        XCTAssertEqual(lines.last?.upperBound, words.count)
        for (a, b) in zip(lines, lines.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }
    }

    func testABreakStartsAParagraphAfterAnEmptyLine() {
        let words = ["one", "two", "three", "four", "five"]
        let lines = PassageLayout.lines(words: words, maxWidth: 10_000, breaks: [3])
        XCTAssertEqual(lines, [0..<3, 3..<3, 3..<5])
        XCTAssertEqual(PassageLayout.lineIndex(containing: 3, in: lines), 2, "The cursor line skips the empty one")
        XCTAssertEqual(PassageLayout.lines(words: words, maxWidth: 10_000), [0..<5])
    }

    func testRandomPassageExcludes() {
        let src = BundledPassages(defaults: temporaryDefaults())
        for _ in 0..<50 {
            XCTAssertNotEqual(src.nextPassage(excluding: ["biology-cell-energy"]).id, "biology-cell-energy")
        }
    }
}
