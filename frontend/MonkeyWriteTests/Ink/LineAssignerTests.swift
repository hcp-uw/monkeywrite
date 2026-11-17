import PencilKit
import XCTest
@testable import MonkeyWrite

final class LineAssignerTests: XCTestCase {
    /// Bands: line i is [10 + 100i, 110 + 100i).
    private let layout = PaperLayout(lineHeight: 100, topInset: 10)

    /// A vertical letter stroke on `line`, spanning fractions of the band
    /// (0 = band top, 1 = rule). Values outside 0...1 reach other lines.
    private func letter(line: Int, from top: CGFloat, to bottom: CGFloat, x: CGFloat = 100,
                        id: UUID = UUID()) -> StrokeGeometry {
        let base = layout.band(ofLine: line).lowerBound
        return StrokeGeometry(id: id, points: [
            CGPoint(x: x, y: base + top * 100),
            CGPoint(x: x + 30, y: base + (top + bottom) * 50),
            CGPoint(x: x + 10, y: base + bottom * 100),
        ])
    }

    private func mark(line: Int, at fraction: CGFloat, x: CGFloat, size: CGFloat = 4) -> StrokeGeometry {
        let y = layout.band(ofLine: line).lowerBound + fraction * 100
        return StrokeGeometry(id: UUID(), points: [CGPoint(x: x, y: y), CGPoint(x: x + size, y: y + size)])
    }

    func testPaperLayoutBands() {
        XCTAssertEqual(layout.band(ofLine: 0), 10..<110)
        XCTAssertEqual(layout.ruleY(forLine: 2), 310)
        XCTAssertEqual(layout.line(containing: 109.9), 0)
        XCTAssertEqual(layout.line(containing: 110), 1)
        XCTAssertEqual(PaperLayout.lineCount(visibleLines: 5, highestUsedLine: nil), 7)
        XCTAssertEqual(PaperLayout.lineCount(visibleLines: 5, highestUsedLine: 0), 7)
        XCTAssertEqual(PaperLayout.lineCount(visibleLines: 5, highestUsedLine: 4), 10)
        XCTAssertEqual(PaperLayout.fitting(height: 510, visibleLines: 5, topInset: 10).lineHeight, 100)
    }

    func testNormalStrokesLandOnTheirLines() {
        let strokes = (0..<4).map { letter(line: $0, from: 0.4, to: 0.95) }
        let lines = LineAssigner.assign(strokes, layout: layout)
        XCTAssertEqual(strokes.map { lines[$0.id] }, [0, 1, 2, 3])
    }

    func testDeepDescenderStaysOnItsLine() {
        // A "g": bowl in the x-height, tail 80% of a line into the line below.
        let g = letter(line: 1, from: 0.45, to: 1.8)
        // A "y" written mostly as descender.
        let y = letter(line: 2, from: 0.55, to: 1.8, x: 200)
        let lines = LineAssigner.assign([g, y], layout: layout)
        XCTAssertEqual(lines[g.id], 1)
        XCTAssertEqual(lines[y.id], 2)
    }

    func testAscenderStaysOnItsLine() {
        // An "l" whose top rises 30% into the line above.
        let l = letter(line: 2, from: -0.3, to: 0.95)
        XCTAssertEqual(LineAssigner.assign([l], layout: layout)[l.id], 2)
    }

    func testDotsAndCrossbarsJoinTheirLetter() {
        // An "i" stem on line 1 with its dot high above, in line 0's band.
        let stem = letter(line: 1, from: 0.5, to: 0.95, x: 100)
        let dot = mark(line: 0, at: 0.85, x: 108, size: 3)
        // A "t" whose short crossbar was drawn just above the rule, in line 0's band.
        let tStem = letter(line: 1, from: 0.05, to: 0.95, x: 300)
        let crossbar = StrokeGeometry(id: UUID(), points: [CGPoint(x: 290, y: 105), CGPoint(x: 315, y: 106)])
        // A period right after a word whose letters sit on line 2.
        let word = letter(line: 2, from: 0.4, to: 0.95, x: 500)
        let period = mark(line: 2, at: 0.93, x: 548, size: 2)
        let lines = LineAssigner.assign([stem, dot, tStem, crossbar, word, period], layout: layout)
        XCTAssertEqual(lines[dot.id], 1, "The dot adopts its stem's line, not the band it sits in")
        XCTAssertEqual(lines[crossbar.id], 1)
        XCTAssertEqual(lines[period.id], 2)
    }

    func testLoneMarkUsesThePrimaryRule() {
        let far = letter(line: 0, from: 0.4, to: 0.95, x: 100)
        let dot = mark(line: 3, at: 0.5, x: 800)
        XCTAssertEqual(LineAssigner.assign([far, dot], layout: layout)[dot.id], 3)
    }

    func testStrokesAboveTheFirstRuleClampToLineZero() {
        let high = StrokeGeometry(id: UUID(), points: [CGPoint(x: 10, y: -80), CGPoint(x: 60, y: -10)])
        let inset = StrokeGeometry(id: UUID(), points: [CGPoint(x: 10, y: 0), CGPoint(x: 60, y: 5)])
        let lines = LineAssigner.assign([high, inset], layout: layout)
        XCTAssertEqual(lines[high.id], 0)
        XCTAssertEqual(lines[inset.id], 0)
    }

    // MARK: Writing below a written line

    // Letter shapes as (top, bottom) fractions of a band, like `letter`.
    private let xHeight: (CGFloat, CGFloat) = (0.5, 0.95)
    private let ascender: (CGFloat, CGFloat) = (0.1, 0.95)
    /// Large handwriting: an ascender or capital rising 0.6 lh above its band.
    private let tall: (CGFloat, CGFloat) = (-0.6, 0.95)
    /// A deep descender whose tail reaches 0.8 lh into the band below: on its
    /// own, as ambiguous as an ascender of the next line.
    private let descender: (CGFloat, CGFloat) = (0.45, 1.8)

    private func letters(line: Int, _ specs: [(x: CGFloat, shape: (CGFloat, CGFloat))]) -> [StrokeGeometry] {
        specs.map { letter(line: line, from: $0.shape.0, to: $0.shape.1, x: $0.x) }
    }

    /// A nearly flat stroke `width` wide at `fraction` of `line`'s band.
    private func bar(line: Int, at fraction: CGFloat, x: CGFloat, width: CGFloat) -> StrokeGeometry {
        let y = layout.band(ofLine: line).lowerBound + fraction * 100
        return StrokeGeometry(id: UUID(), points: [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y + 2)])
    }

    /// A normal line 1 across x 60...760, in drawing order, with descenders
    /// (x 320, 460, 540: tails reach y 290, 0.8 lh into line 2), an i-dot
    /// drawn after its word, and a t-crossbar drawn right after its stem.
    private func writtenLineOne() -> [StrokeGeometry] {
        var strokes = letters(line: 1, [(60, ascender), (100, xHeight), (140, xHeight)])
        strokes += letters(line: 1, [(240, xHeight), (280, xHeight), (320, descender)])
        strokes.append(mark(line: 1, at: 0.35, x: 288))
        strokes += letters(line: 1, [(420, xHeight), (460, descender), (500, xHeight), (540, descender)])
        strokes += letters(line: 1, [(640, ascender)])
        strokes.append(bar(line: 1, at: 0.45, x: 632, width: 25))
        strokes += letters(line: 1, [(680, xHeight), (720, xHeight)])
        return strokes
    }

    /// Line 2 in large handwriting right under `writtenLineOne`, in drawing
    /// order: "The" (tall T stem, a T-bar high in line 1's band, tall h, e),
    /// "lin" (tall l, an i under line 1's descender at 320 with its dot drawn
    /// after the word, inside that descender's bounds), "tuvw" (a tall t under
    /// the descender at 460 with its crossbar inside that descender's bounds).
    private func largeLineTwo() -> [StrokeGeometry] {
        var strokes = letters(line: 2, [(60, tall)])
        strokes.append(bar(line: 2, at: -0.65, x: 45, width: 60))
        strokes += letters(line: 2, [(120, tall), (160, xHeight)])
        strokes += letters(line: 2, [(260, tall), (320, xHeight), (360, xHeight)])
        strokes.append(mark(line: 2, at: 0.25, x: 328))
        strokes += letters(line: 2, [(460, tall)])
        strokes.append(bar(line: 2, at: 0.4, x: 450, width: 25))
        strokes += letters(line: 2, [(500, xHeight), (540, xHeight), (580, xHeight)])
        return strokes
    }

    func testTallLettersOfANewWordStayOnTheirLine() {
        // Line 2 already has a word; the next word starts with tall letters
        // rising 0.6 lh into line 1's band. Every stroke must stay on line 2
        // the moment it is drawn, not only once the word is finished.
        let lineOne = letters(line: 1, [(60, xHeight), (100, descender), (140, ascender), (180, xHeight),
                                        (260, xHeight), (300, descender), (340, xHeight)])
        let previousWord = letters(line: 2, [(60, xHeight), (100, xHeight)])
        let newWord = letters(line: 2, [(200, tall), (240, xHeight), (280, tall), (320, tall), (360, xHeight)])
        let all = lineOne + previousWord + newWord
        for count in (lineOne.count + previousWord.count + 1)...all.count {
            let lines = LineAssigner.assign(Array(all.prefix(count)), layout: layout)
            for stroke in all.prefix(count) {
                XCTAssertEqual(lines[stroke.id], lineOne.contains(stroke) ? 1 : 2,
                               "After \(count) strokes, stroke at x \(stroke.bounds.minX)")
            }
        }
    }

    func testTallCapitalStartingALineBelowTextStaysOnItsLine() {
        // The first strokes of line 2 have no word around them yet; line 1's
        // ink right above them shows they are not part of line 1.
        let lineOne = writtenLineOne()
        let lineTwo = largeLineTwo()
        let stem = lineTwo[0], tBar = lineTwo[1], h = lineTwo[2]
        for count in 1...3 {
            let lines = LineAssigner.assign(lineOne + lineTwo.prefix(count), layout: layout)
            for stroke in [stem, tBar, h].prefix(count) {
                XCTAssertEqual(lines[stroke.id], 2, "After \(count) line-2 strokes")
            }
        }
    }

    func testIDotNearADescenderOfTheLineAboveJoinsItsStem() {
        // Line 1's "g" tail hangs over line 2's "i"; the dot sits inside the tail's bounds.
        let g = letter(line: 1, from: 0.45, to: 1.6, x: 300)
        let stem = letter(line: 2, from: 0.55, to: 0.95, x: 310)
        let dot = mark(line: 2, at: 0.25, x: 315)
        XCTAssertEqual(LineAssigner.assign([g, stem, dot], layout: layout)[dot.id], 2, "Dot right after its stem")
        // The dot drawn after the rest of the word, far from the last letter.
        let rest = letters(line: 2, [(350, xHeight), (390, xHeight), (430, xHeight)])
        let lines = LineAssigner.assign([g, stem] + rest + [dot], layout: layout)
        XCTAssertEqual(lines[dot.id], 2, "Delayed dot")
        XCTAssertEqual(lines[g.id], 1)
    }

    func testCrossbarNearADescenderOfTheLineAboveJoinsItsStem() {
        // Line 1's "y" tail hangs over line 2's "t"; the crossbar touches both.
        let y = letter(line: 1, from: 0.45, to: 1.6, x: 500)
        let t = letter(line: 2, from: 0.2, to: 0.95, x: 505)
        let crossbar = bar(line: 2, at: 0.45, x: 495, width: 25)
        XCTAssertEqual(LineAssigner.assign([y, t, crossbar], layout: layout)[crossbar.id], 2)
        let rest = letters(line: 2, [(560, xHeight), (600, xHeight)])
        let lines = LineAssigner.assign([y, t] + rest + [crossbar], layout: layout)
        XCTAssertEqual(lines[crossbar.id], 2, "Crossbar drawn after the word")
        XCTAssertEqual(lines[y.id], 1)
    }

    func testWritingTheNextLineNeverMovesTheLineAbove() {
        let lineOne = writtenLineOne()
        let lineTwo = largeLineTwo()
        let lineOneIDs = Set(lineOne.map(\.id))
        let all = lineOne + lineTwo
        let before = LineAssigner.assign(lineOne, layout: layout)
        XCTAssertEqual(Set(before.values), [1])
        for count in lineOne.count...all.count {
            let lines = LineAssigner.assign(Array(all.prefix(count)), layout: layout)
            for stroke in all.prefix(count) {
                XCTAssertEqual(lines[stroke.id], lineOneIDs.contains(stroke.id) ? 1 : 2,
                               "After \(count) strokes, stroke at x \(stroke.bounds.minX) y \(stroke.bounds.minY)")
            }
        }
    }

    func testGoingBackToFixTheLineAboveStaysThere() {
        // After writing line 2, the writer adds letters to line 1's third word
        // (right above line 2's last letters), including a descender whose
        // tail reaches line 2's letters, and dots an i there.
        let lineOne = writtenLineOne()
        let lineTwo = largeLineTwo()
        let fixG = letter(line: 1, from: 0.45, to: 1.6, x: 580)
        let fixStem = letter(line: 1, from: 0.5, to: 0.95, x: 600)
        let fixDot = mark(line: 1, at: 0.35, x: 606)
        let lines = LineAssigner.assign(lineOne + lineTwo + [fixG, fixStem, fixDot], layout: layout)
        XCTAssertEqual(lines[fixG.id], 1)
        XCTAssertEqual(lines[fixStem.id], 1)
        XCTAssertEqual(lines[fixDot.id], 1)
        for stroke in lineTwo { XCTAssertEqual(lines[stroke.id], 2) }
        // The descender alone (the first fix stroke) too.
        XCTAssertEqual(LineAssigner.assign(lineOne + lineTwo + [fixG], layout: layout)[fixG.id], 1)
        // A deep descender drawn right after line 2's letter below it is
        // genuinely ambiguous on its own; the next letter settles it.
        let deepG = letter(line: 1, from: 0.45, to: 1.8, x: 580)
        let deepLines = LineAssigner.assign(lineOne + lineTwo + [deepG, fixStem], layout: layout)
        XCTAssertEqual(deepLines[deepG.id], 1)
        XCTAssertEqual(deepLines[fixStem.id], 1)
    }

    func testShortDescenderIsNotAnAscenderOfTheNextLine() {
        // Its bottom floats far above line 2's rule, so line 2's word right
        // after it cannot claim it.
        let y = letter(line: 1, from: 0.45, to: 1.6, x: 500)
        let t = letter(line: 2, from: 0.2, to: 0.95, x: 505)
        XCTAssertEqual(LineAssigner.candidateLines(of: y, layout: layout), [1])
        XCTAssertEqual(LineAssigner.assign([y, t], layout: layout)[y.id], 1)
    }

    func testLetterOfTheLineAboveWrittenNextToItsWordStaysThere() {
        // Line 1's word gets its last letter, a tall one, while line 2 is empty.
        let word = letters(line: 1, [(60, xHeight), (100, xHeight)])
        let tallLast = letter(line: 1, from: -0.6, to: 0.95, x: 140)
        XCTAssertEqual(LineAssigner.assign(word + [tallLast], layout: layout)[tallLast.id], 1)
    }

    func testRealStrokesApplyTheirTransform() {
        // Drawn on line 0 in stroke space, moved down three lines by its transform.
        let stroke = makeStroke(from: CGPoint(x: 10, y: 40), to: CGPoint(x: 90, y: 100))
            .withTransform(CGAffineTransform(translationX: 0, y: 300))
        let other = makeStroke(from: CGPoint(x: 10, y: 140), to: CGPoint(x: 90, y: 200))
        let lines = LineAssigner.assign([stroke, other], layout: layout)
        XCTAssertEqual(lines[stroke.id], 3)
        XCTAssertEqual(lines[other.id], 1)
        let byLine = LineAssigner.strokesByLine([stroke, other], layout: layout)
        XCTAssertEqual(byLine[3]?.map(\.id), [stroke.id])
    }
}

private extension PKStroke {
    func withTransform(_ transform: CGAffineTransform) -> PKStroke {
        var copy = self
        copy.transform = transform
        return copy
    }
}
