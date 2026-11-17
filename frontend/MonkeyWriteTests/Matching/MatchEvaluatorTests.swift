import XCTest
@testable import MonkeyWrite

final class MatchEvaluatorTests: XCTestCase {
    private let locked: Int?? = .some(nil)   // no active line: every word locked

    func testExactMatchAllCorrect() {
        let s = MT.evaluate("The cat sat.", ["the cat sat"], active: locked)
        XCTAssertEqual(MT.statuses(s), [.correct, .correct, .correct])
        XCTAssertEqual(s.words[2].chars, [.correct, .correct, .correct, .correct])
        XCTAssertTrue(s.isComplete)
    }

    func testCaseAndPunctuationLeniency() {
        let s = MT.evaluate("The Holmes, don't stop", ["the holmes dont Stop."], active: locked)
        XCTAssertEqual(MT.statuses(s), [.correct, .correct, .correct, .correct])
        XCTAssertEqual(s.words[1].chars, Array(repeating: .correct, count: 7))
        // Wrong punctuation is ignored too.
        let t = MT.evaluate("Holmes, said", ["Holmes; said!"], active: locked)
        XCTAssertEqual(MT.statuses(t), [.correct, .correct])
    }

    func testStrayPunctuationWordIgnored() {
        let s = MT.evaluate("the cat sat", ["the , cat sat"], active: locked)
        XCTAssertEqual(MT.statuses(s), [.correct, .correct, .correct])
    }

    func testMisspellingIsIncorrectNotMissed() {
        let s = MT.evaluate("the cat sat on", ["the cta sat"], active: locked)
        XCTAssertEqual(MT.statuses(s), [.correct, .incorrect, .correct, .pending])
    }

    func testPerCharColoringOfMisspeltWord() {
        let s = MT.evaluate("the end", ["tbe end"], active: locked)
        XCTAssertEqual(s.words[0].status, .incorrect)
        XCTAssertEqual(s.words[0].chars, [.correct, .incorrect, .correct])
        // Missing letter, punctuation inherits nearest preceding letter.
        let t = MT.evaluate("Holmes, said", ["Hlmes said"], active: locked)
        XCTAssertEqual(t.words[0].chars, [.correct, .incorrect, .correct, .correct, .correct, .correct, .correct])
        // Leading quote inherits the first letter; missing trailing letter.
        let u = MT.evaluate("\"Holmes said", ["Holme said"], active: locked)
        XCTAssertEqual(u.words[0].chars, [.correct, .correct, .correct, .correct, .correct, .correct, .incorrect])
    }

    func testSkippedWordMissed() {
        let s = MT.evaluate("the cat sat on", ["the sat on"], active: locked)
        XCTAssertEqual(MT.statuses(s), [.correct, .missed, .correct, .correct])
        XCTAssertEqual(s.words[1].chars, [.incorrect, .incorrect, .incorrect])
    }

    func testExtraWordIgnored() {
        let s = MT.evaluate("the cat sat", ["the big cat sat"], active: locked)
        XCTAssertEqual(MT.statuses(s), [.correct, .correct, .correct])
    }

    func testMergeAndSplitCorrect() {
        let s = MT.evaluate("see you today now", ["see you to day now"], active: locked)
        XCTAssertEqual(MT.statuses(s), [.correct, .correct, .correct, .correct])
        let t = MT.evaluate("end of the day", ["end ofthe day"], active: locked)
        XCTAssertEqual(MT.statuses(t), [.correct, .correct, .correct, .correct])
    }

    func testTrailingUnwrittenPending() {
        let s = MT.evaluate("the cat sat on the mat", ["the cat"], active: locked)
        XCTAssertEqual(MT.statuses(s), [.correct, .correct, .pending, .pending, .pending, .pending])
        XCTAssertEqual(s.words[2].chars, [.pending, .pending, .pending])
        XCTAssertFalse(s.isComplete)
        XCTAssertEqual(s.cursorWordIndex, 2)
    }

    func testNothingWritten() {
        let s = MT.evaluate("a b", [], active: locked)
        XCTAssertEqual(MT.statuses(s), [.pending, .pending])
        XCTAssertEqual(s.cursorWordIndex, 0)
        XCTAssertFalse(s.isComplete)
    }

    func testOpenWordNeutral() {
        let s = MT.evaluate("the cat sat", ["the ca"])
        XCTAssertEqual(MT.statuses(s), [.correct, .open, .pending])
        XCTAssertEqual(s.words[1].chars, [.current, .current, .current])
        XCTAssertEqual(s.cursorWordIndex, 1)
    }

    func testOpenWordLive() {
        let live = MT.settings(coloring: .live)
        let s = MT.evaluate("the cat sat", ["the ca"], settings: live)
        XCTAssertEqual(s.words[1].status, .open)
        XCTAssertEqual(s.words[1].chars, [.correct, .correct, .pending])
        // A wrong last letter stays neutral until a letter follows it.
        let t = MT.evaluate("the cat sat", ["the cx"], settings: live)
        XCTAssertEqual(t.words[1].chars, [.correct, .current, .pending])
        let u = MT.evaluate("the cat sat", ["the cxt"], settings: live)
        XCTAssertEqual(u.words[1].chars, [.correct, .incorrect, .correct])
        // Locked, the same letter is red.
        let v = MT.evaluate("the cat sat", ["the cx"], active: locked, settings: live)
        XCTAssertEqual(v.words[1].chars, [.correct, .incorrect, .incorrect])
    }

    func testLiveColoringGraceForTheTrailingLetter() {
        func live(_ written: String) -> [CharState] {
            LetterColoring.letterStates(passage: MatchKey.key("that"), written: MatchKey.key(written), live: true)
        }
        XCTAssertEqual(live("l"), [.current, .pending, .pending, .pending], "First stroke of a t")
        XCTAssertEqual(live("th"), [.correct, .correct, .pending, .pending])
        XCTAssertEqual(live("the"), [.correct, .correct, .current, .pending], "Recognizer completed the fragment")
        XCTAssertEqual(live("thet"), [.correct, .correct, .incorrect, .correct], "A later correct letter makes it red")
        XCTAssertEqual(live("txy"), [.correct, .current, .current, .pending], "The whole trailing run waits")
        XCTAssertEqual(LetterColoring.letterStates(passage: MatchKey.key("that"), written: MatchKey.key("the"), live: false),
                       [.correct, .correct, .incorrect, .incorrect], "Locked words are unaffected")
    }

    func testOpenWordPartialMergeAndSplit() {
        let live = MT.settings(coloring: .live)
        // "to" locked + "da" open is a prefix of "today".
        let s = MT.evaluate("see today now", ["see to da"], settings: live)
        XCTAssertEqual(MT.statuses(s), [.correct, .open, .pending])
        XCTAssertEqual(s.words[1].chars, [.correct, .correct, .correct, .correct, .pending])
        // "ofth" open covers "of" + prefix of "the".
        let t = MT.evaluate("end of the day", ["end ofth"], settings: live)
        XCTAssertEqual(MT.statuses(t), [.correct, .open, .open, .pending])
        XCTAssertEqual(t.words[2].chars, [.correct, .correct, .pending])
    }

    func testOnlyLastWordOfActiveLineIsOpen() {
        // Active line 0 while line 1 is written: last word of line 0 is open.
        let s = MT.evaluate("a b c d e", ["a b", "c d"], active: .some(0))
        XCTAssertEqual(MT.statuses(s), [.correct, .open, .correct, .correct, .pending])
    }

    func testCompletionWhenLastWordCorrectWhileOpen() {
        let s = MT.evaluate("the cat sat.", ["the cat sat"])
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(s.words[2].status, .correct)
    }

    func testNoCompletionWhenLastWordWrong() {
        let s = MT.evaluate("the cat sat", ["the cat sit"])
        XCTAssertFalse(s.isComplete)
        let t = MT.evaluate("the cat sat", ["the cat sit"], active: locked)
        XCTAssertFalse(t.isComplete)
        XCTAssertEqual(t.words[2].status, .incorrect)
    }

    func testEarlierErrorsDoNotBlockCompletion() {
        let s = MT.evaluate("the cat sat on the mat", ["teh cat on the mat"])
        XCTAssertEqual(MT.statuses(s), [.incorrect, .correct, .missed, .correct, .correct, .correct])
        XCTAssertTrue(s.isComplete)
    }

    func testCompletionWithTrailingPunctuationWord() {
        let s = MT.evaluate("the end —", ["the end"])
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(MT.statuses(s), [.correct, .correct, .correct])
    }

    func testLetterlessPassageWordCorrectOnceReached() {
        let s = MT.evaluate("one — two three", ["one two"])
        XCTAssertEqual(MT.statuses(s), [.correct, .correct, .open, .pending])
        let t = MT.evaluate("one — two three", ["one"])
        XCTAssertEqual(MT.statuses(t), [.open, .pending, .pending, .pending])
    }

    func testCursorStaysAtFurthestProgressWhenFixingEarlierLine() {
        let text = "a b c d e f g h i j"
        // Lines 1 and 2 written; user is now rewriting the last word on line 0.
        let s = MT.evaluate(text, ["a b cc", "d e f", "g h"], active: .some(0))
        XCTAssertEqual(s.words[2].status, .open)
        XCTAssertEqual(s.cursorWordIndex, 8)
    }

    func testCursorClampsAtEnd() {
        let s = MT.evaluate("a b", ["a b c d"], active: locked)
        XCTAssertEqual(s.cursorWordIndex, 1)
    }

    func testWrittenBeyondPassageEndIgnored() {
        let s = MT.evaluate("the end", ["the end and then some"], active: locked)
        XCTAssertEqual(MT.statuses(s), [.correct, .correct])
        XCTAssertTrue(s.isComplete)
    }

    // MARK: Vision leniency

    func testVisionOffIgnoresAlternatives() {
        let snap = MT.snapshot(words: [[MT.word("the"), MT.word("cot", alternatives: ["cat"]), MT.word("sat")]], active: nil)
        var session = MatchSession(passage: MT.passage("the cat sat"))
        let s = session.evaluate(snap, settings: MT.settings(vision: false))
        XCTAssertEqual(s.words[1].status, .incorrect)
        XCTAssertFalse(s.words[1].assisted)
        XCTAssertTrue(s.wordsNeedingVision.isEmpty)
    }

    func testVisionAcceptsTopThreeButNotFourth() {
        var session = MatchSession(passage: MT.passage("the cat sat"))
        let third = MT.snapshot(words: [[MT.word("the"), MT.word("cot", alternatives: ["cut", "cog", "Cat"]), MT.word("sat")]], active: nil)
        let s = session.evaluate(third, settings: MT.settings(vision: true))
        XCTAssertEqual(s.words[1].status, .correct)
        XCTAssertTrue(s.words[1].assisted)
        XCTAssertEqual(s.words[1].chars, [.correct, .correct, .correct])

        var session2 = MatchSession(passage: MT.passage("the cat sat"))
        let fourth = MT.snapshot(words: [[MT.word("the"), MT.word("cot", alternatives: ["cut", "cog", "cit", "cat"]), MT.word("sat")]], active: nil)
        let t = session2.evaluate(fourth, settings: MT.settings(vision: true))
        XCTAssertEqual(t.words[1].status, .incorrect)
        XCTAssertTrue(t.wordsNeedingVision.isEmpty, "alternatives already checked")
    }

    func testWordsNeedingVision() {
        let ids = [UUID(), UUID()]
        let snap = MT.snapshot(words: [[MT.word("the"), MT.word("cot", ids: ids), MT.word("sa")]], active: 0)
        var session = MatchSession(passage: MT.passage("the cat sat"))
        let s = session.evaluate(snap, settings: MT.settings(vision: true))
        XCTAssertEqual(s.wordsNeedingVision, [ids])   // open "sa" is not included
        let off = session.evaluate(snap, settings: MT.settings(vision: false))
        XCTAssertTrue(off.wordsNeedingVision.isEmpty)
    }

    func testVisionCompletesOpenLastWordOnlyWithLeniency() {
        let snap = MT.snapshot(words: [[MT.word("the"), MT.word("cat"), MT.word("sot", alternatives: ["sat"])]], active: 0)
        var session = MatchSession(passage: MT.passage("the cat sat"))
        XCTAssertFalse(session.evaluate(snap, settings: MT.settings(vision: false)).isComplete)
        let s = session.evaluate(snap, settings: MT.settings(vision: true))
        XCTAssertTrue(s.isComplete)
        XCTAssertTrue(s.words[2].assisted)
    }

    // MARK: Open word

    /// "the cat sat" with "cat" rewritten as `cat` (its stroke the newest).
    private func rewrite(_ cat: String, ids: [UUID], newest: UUID?) -> WritingSnapshot {
        var snap = MT.snapshot(words: [[MT.word("the"), MT.word(cat, ids: ids), MT.word("sat")]], active: 0)
        snap.activeStrokeID = newest
        return snap
    }

    func testOpenWordIsTheWordHoldingTheNewestStroke() {
        let stroke = UUID()
        var session = MatchSession(passage: MT.passage("the cat sat on"))
        let s = session.evaluate(rewrite("ca", ids: [UUID(), stroke], newest: stroke), settings: MT.settings())
        XCTAssertEqual(MT.statuses(s), [.correct, .open, .correct, .pending])
        XCTAssertEqual(s.words[1].chars, [.current, .current, .current], "Neutral until locked")
        XCTAssertEqual(s.cursorWordIndex, 3, "The cursor stays at the furthest progress")
        XCTAssertNil(session.firstAttempt[1], "The word being written records nothing")
        XCTAssertEqual(session.firstAttempt[2], true)

        let live = session.evaluate(rewrite("ca", ids: [stroke], newest: stroke), settings: MT.settings(coloring: .live))
        XCTAssertEqual(live.words[1].status, .open)
        XCTAssertEqual(Array(live.words[1].chars.prefix(2)), [.correct, .correct])
        XCTAssertEqual(live.words[2].chars, [.correct, .correct, .correct])
    }

    func testOpenWordFallsBackToTheLastWordOnTheLine() {
        // No word holds the newest stroke (grouping unknown): the line's last word.
        var session = MatchSession(passage: MT.passage("the cat sat on"))
        let unknown = MT.snapshot(words: [[WrittenWord(text: "the", strokeIDs: []), WrittenWord(text: "ca", strokeIDs: []),
                                           WrittenWord(text: "sat", strokeIDs: [])]], active: 0)
        var withStroke = unknown
        withStroke.activeStrokeID = UUID()
        for snap in [unknown, withStroke] {
            let t = session.evaluate(snap, settings: MT.settings())
            XCTAssertEqual(MT.statuses(t), [.correct, .incorrect, .open, .pending])
        }
    }

    // MARK: Underline without an aligned open word

    func testExpectedWordIsOpenWhileTheActiveLineHasNoResult() {
        var session = MatchSession(passage: MT.passage("the cat sat on"))
        // Line 1 holds the newest stroke but is not recognized yet.
        let snap = MT.snapshot(words: [[MT.word("the"), MT.word("cat")]], active: 1)
        let s = session.evaluate(snap, settings: MT.settings(coloring: .live))
        XCTAssertEqual(MT.statuses(s), [.correct, .correct, .open, .pending])
        XCTAssertEqual(s.words[2].chars, [.current, .current, .current], "Nothing is recognized for it")
        XCTAssertEqual(s.cursorWordIndex, 2)
        XCTAssertEqual(session.firstAttempt, [true, true, nil, nil])
        XCTAssertEqual(session.tally(reachedOnly: true).words, 2, "Not counted as attempted")
    }

    func testExpectedWordIsOpenWhileTheNewWordReadsAsPunctuation() {
        let stroke = UUID()
        var session = MatchSession(passage: MT.passage("the cat sat on"))
        // At the end of the writing.
        var atEnd = MT.snapshot(words: [[MT.word("the"), MT.word("cat"), MT.word(",", ids: [stroke])]], active: 0)
        atEnd.activeStrokeID = stroke
        XCTAssertEqual(MT.statuses(session.evaluate(atEnd, settings: MT.settings())), [.correct, .correct, .open, .pending])

        // Rewriting an erased middle word: the gap is open, not missed.
        session = MatchSession(passage: MT.passage("the dog sat on"))
        let s = session.evaluate(rewrite("'", ids: [stroke], newest: stroke), settings: MT.settings())
        XCTAssertEqual(MT.statuses(s), [.correct, .open, .correct, .pending])
        XCTAssertEqual(s.cursorWordIndex, 3)
        XCTAssertNil(session.firstAttempt[1], "Not a failed attempt")
        let tally = session.tally()
        XCTAssertEqual(tally.missed, 0)
        XCTAssertEqual(tally.correct, 2)
    }

    func testOpenWordAlignedAsExtra() {
        // A substitution never costs more than an extra, so an open word is
        // an extra only when the word expected there is written already
        // (here "cat", which the open word was inserted in front of) or the
        // passage has ended. Then nothing gets a stand-in underline: every
        // passage word keeps its state.
        let stroke = UUID()
        XCTAssertEqual(PassageAligner.align(written: ["the", "sat", "cat"], passage: ["the", "cat", "sat"]),
                       [.match(written: 0, passage: 0), .extra(written: 1), .match(written: 2, passage: 1)])
        var session = MatchSession(passage: MT.passage("the cat sat"))
        var inserted = MT.snapshot(words: [[MT.word("the"), MT.word("sat", ids: [stroke]), MT.word("cat")]], active: 0)
        inserted.activeStrokeID = stroke
        XCTAssertEqual(MT.statuses(session.evaluate(inserted, settings: MT.settings())), [.correct, .correct, .pending])

        session = MatchSession(passage: MT.passage("the cat"))
        var pastTheEnd = MT.snapshot(words: [[MT.word("the"), MT.word("cot"), MT.word("xx", ids: [stroke])]], active: 0)
        pastTheEnd.activeStrokeID = stroke
        let s = session.evaluate(pastTheEnd, settings: MT.settings())
        XCTAssertEqual(MT.statuses(s), [.correct, .incorrect])
        XCTAssertFalse(s.isComplete)
    }

    // MARK: Edits keep earlier lines

    func testEditsOnTheLastLineNeverRecolorEarlierLines() {
        // Repeated words, so a careless alignment could move earlier ones.
        let text = "and the dog and the cat saw the dog and the cat and the end"
        let words = text.split(separator: " ").map(String.init)
        let lines = [Array(words[0..<5]), Array(words[5..<10]), Array(words[10..<15])]
        func snapshot(_ last: [WrittenWord], newest: UUID?) -> WritingSnapshot {
            var snap = MT.snapshot(words: [lines[0].map { MT.word($0) }, lines[1].map { MT.word($0) }, last], active: 2)
            snap.activeStrokeID = newest
            return snap
        }
        for coloring in WordColoringMode.allCases {
            let settings = MT.settings(coloring: coloring)
            for gap in 0..<4 {
                let stroke = UUID()
                var session = MatchSession(passage: MT.passage(text))
                let intact = session.evaluate(snapshot(lines[2].map { MT.word($0) }, newest: nil), settings: settings)
                let earlier = Array(intact.words[0..<10])
                XCTAssertEqual(earlier.map(\.status), Array(repeating: .correct, count: 10))
                let original = lines[2][gap]
                for edited in ["", String(original.prefix(1)), String(original.prefix(2)) + "x", "zzqx"] {
                    var last = lines[2].map { MT.word($0) }
                    if edited.isEmpty { last.remove(at: gap) } else { last[gap] = MT.word(edited, ids: [stroke]) }
                    let s = session.evaluate(snapshot(last, newest: edited.isEmpty ? nil : stroke), settings: settings)
                    XCTAssertEqual(Array(s.words[0..<10]), earlier, "gap \(gap) edited \"\(edited)\" \(coloring)")
                    XCTAssertEqual(Array(s.words[10..<(10 + gap)]).map(\.status), Array(repeating: .correct, count: gap),
                                   "Words before the edit on its line stay too")
                }
            }
        }
    }

    func testErasingWordsKeepsTheEarlierRepeatedWord() {
        // "fresh, and" erased: the earlier "and" keeps its passage word.
        let s = MT.evaluate("was bright and fresh, and brimming with life", ["was bright and", "brimming with"])
        XCTAssertEqual(MT.statuses(s), [.correct, .correct, .correct, .missed, .missed, .correct, .open, .pending])
    }
}
