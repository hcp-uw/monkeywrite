import XCTest
@testable import MonkeyWrite

final class MatchSessionTests: XCTestCase {
    private let text = "the cat sat on the mat"

    func testWrongThenFixedCountsAsCorrectedNotFirstAttempt() {
        var session = MatchSession(passage: MT.passage(text))
        let settings = MT.settings()
        _ = session.evaluate(MT.snapshot(["the cta sat"]), settings: settings)   // "cta" locked, "sat" open
        XCTAssertEqual(session.firstAttempt[1], false)
        XCTAssertNil(session.firstAttempt[2], "open word is not recorded")
        // Fix line 0, then finish on line 1.
        _ = session.evaluate(MT.snapshot(["the cat sat"], active: .some(0)), settings: settings)
        let done = session.evaluate(MT.snapshot(["the cat sat", "on the mat"]), settings: settings)
        XCTAssertTrue(done.isComplete)
        XCTAssertEqual(session.firstAttempt[1], false, "never overwritten")
        let r = session.result(duration: 60, mode: .passage, settings: settings)
        XCTAssertEqual(r.correctWords, 6)
        XCTAssertEqual(r.wordsCorrected, 1)
        XCTAssertEqual(r.accuracy, 5.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(r.totalWords, 6)
        XCTAssertEqual(r.missedWords, 0)
    }

    func testPendingLinesDoNotRecordFirstAttempts() {
        var session = MatchSession(passage: MT.passage(text))
        let settings = MT.settings()
        // Line 0 is being re-analyzed: its (stale) misreading must not record.
        _ = session.evaluate(MT.snapshot(["the cta", "sat on"], pending: [0]), settings: settings)
        XCTAssertNil(session.firstAttempt[0])
        XCTAssertNil(session.firstAttempt[1])
        XCTAssertEqual(session.firstAttempt[2], true)
        _ = session.evaluate(MT.snapshot(["the cat", "sat on"]), settings: settings)
        XCTAssertEqual(session.firstAttempt[1], true)
    }

    func testTransientSkipBehindOpenWordNotRecorded() {
        // Dissimilar words, so the skip is cheaper than a substitution.
        var session = MatchSession(passage: MT.passage("the dog sat on the mat"))
        let settings = MT.settings()
        // "sat" open after "the": dog is missed only transiently.
        let s = session.evaluate(MT.snapshot(["the sat"]), settings: settings)
        XCTAssertEqual(s.words[1].status, .missed)
        XCTAssertNil(session.firstAttempt[1])
        // Once a later word is locked, the skip is a failed first attempt.
        _ = session.evaluate(MT.snapshot(["the sat on"]), settings: settings)
        XCTAssertEqual(session.firstAttempt[1], false)
    }

    func testMissedThenWrittenIsCorrected() {
        var session = MatchSession(passage: MT.passage("the dog sat on the mat"))
        let settings = MT.settings()
        _ = session.evaluate(MT.snapshot(["the sat on"]), settings: settings)
        XCTAssertEqual(session.firstAttempt[1], false)
        _ = session.evaluate(MT.snapshot(["the dog sat on the mat"]), settings: settings)
        let r = session.result(duration: 30, mode: .passage, settings: settings)
        XCTAssertEqual(r.wordsCorrected, 1)
        XCTAssertEqual(r.accuracy, 5.0 / 6.0, accuracy: 1e-9)
    }

    func testCompletionRecordsOpenLastWord() {
        var session = MatchSession(passage: MT.passage("a b"))
        _ = session.evaluate(MT.snapshot(["a b"]), settings: MT.settings())
        XCTAssertEqual(session.firstAttempt, [true, true])
        XCTAssertEqual(session.result(duration: 10, mode: .passage, settings: MT.settings()).accuracy, 1)
    }

    func testLateVisionAlternativesUpgradeFirstAttempt() {
        let ids = [UUID()]
        var session = MatchSession(passage: MT.passage("the cat sat on"))
        let on = MT.settings(vision: true)
        let before = MT.snapshot(words: [[MT.word("the"), MT.word("cot", ids: ids), MT.word("sat"), MT.word("o")]], active: 0)
        let s = session.evaluate(before, settings: on)
        XCTAssertEqual(s.wordsNeedingVision, [ids])
        XCTAssertEqual(session.firstAttempt[1], false)
        let after = MT.snapshot(words: [[MT.word("the"), MT.word("cot", alternatives: ["cat"], ids: ids), MT.word("sat"), MT.word("o")]], active: 0)
        let t = session.evaluate(after, settings: on)
        XCTAssertTrue(t.words[1].assisted)
        XCTAssertEqual(session.firstAttempt[1], true)
        let r = session.result(duration: 60, mode: .passage, settings: on)
        XCTAssertEqual(r.assistedWords, 1)
        XCTAssertEqual(r.wordsCorrected, 0)
    }

    func testLateVisionWithoutStrokeIDsDoesNotUpgrade() {
        var session = MatchSession(passage: MT.passage("the cat sat on"))
        let on = MT.settings(vision: true)
        let before = MT.snapshot(words: [[MT.word("the"), MT.word("cot", ids: []), MT.word("sat"), MT.word("o")]], active: 0)
        XCTAssertTrue(session.evaluate(before, settings: on).wordsNeedingVision.isEmpty)
        let after = MT.snapshot(words: [[MT.word("the"), MT.word("cot", alternatives: ["cat"], ids: []), MT.word("sat"), MT.word("o")]], active: 0)
        _ = session.evaluate(after, settings: on)
        XCTAssertEqual(session.firstAttempt[1], false)
        XCTAssertEqual(session.result(duration: 60, mode: .passage, settings: on).wordsCorrected, 1)
    }

    func testWPMMath() {
        // "Hello, world foo" : lengths 6 ("Hello,"), 5, 3.
        var session = MatchSession(passage: MT.passage("Hello, world foo"))
        let settings = MT.settings()
        _ = session.evaluate(MT.snapshot(["hello wrold foo"]), settings: settings)
        let r = session.result(duration: 60, mode: .passage, settings: settings)
        // correct: "Hello," (6+1) + "foo" (3, last word, no space) = 10 chars -> 2 wpm
        XCTAssertEqual(r.wpm, 2, accuracy: 1e-9)
        // raw adds "world" (5+1): 16 chars -> 3.2 wpm
        XCTAssertEqual(r.rawWPM, 3.2, accuracy: 1e-9)
        XCTAssertEqual(r.correctWords, 2)
        XCTAssertTrue(r.wpm <= r.rawWPM)
        let half = session.result(duration: 30, mode: .passage, settings: settings)
        XCTAssertEqual(half.wpm, 4, accuracy: 1e-9)
    }

    func testMissedAndPendingNotInRawWPM() {
        var session = MatchSession(passage: MT.passage("aaaa bbbb cccc dddd"))
        _ = session.evaluate(MT.snapshot(["aaaa cccc"], active: .some(nil)), settings: MT.settings())
        let r = session.result(duration: 60, mode: .passage, settings: MT.settings())
        XCTAssertEqual(r.rawWPM, 2, accuracy: 1e-9)   // (5 + 5) / 5
        XCTAssertEqual(r.missedWords, 1)
    }

    func testZeroDurationGuarded() {
        var session = MatchSession(passage: MT.passage("a b"))
        _ = session.evaluate(MT.snapshot(["a b"]), settings: MT.settings())
        for d in [0.0, -5.0] {
            let r = session.result(duration: d, mode: .passage, settings: MT.settings())
            XCTAssertEqual(r.wpm, 0)
            XCTAssertEqual(r.rawWPM, 0)
            XCTAssertFalse(r.wpm.isNaN || r.wpm.isInfinite)
        }
    }

    func testResetClearsHistory() {
        var session = MatchSession(passage: MT.passage("a b"))
        _ = session.evaluate(MT.snapshot(["x b"]), settings: MT.settings())
        session.reset()
        XCTAssertEqual(session.firstAttempt, [nil, nil])
        XCTAssertNil(session.lastState)
        let r = session.result(duration: 60, mode: .passage, settings: MT.settings())
        XCTAssertEqual(r.correctWords, 0)
        XCTAssertEqual(r.accuracy, 0)
    }

    func testAppendKeepsHistoryAndEarlierWords() {
        var session = MatchSession(passage: MT.passage("the cat sat"))
        let settings = MT.settings()
        _ = session.evaluate(MT.snapshot(["the cta sat"], active: .some(nil)), settings: settings)
        _ = session.evaluate(MT.snapshot(["the cat sat"]), settings: settings)
        XCTAssertEqual(session.firstAttempt, [true, false, true])
        XCTAssertEqual(session.passagesCompleted, 1)

        // Repeated words across the boundary.
        session.append(Passage(id: "next", text: "the cat ran off", source: "Next"))
        XCTAssertEqual(session.passageEnds, [3, 7])
        XCTAssertEqual(session.firstAttempt, [true, false, true, nil, nil, nil, nil], "History kept, new words fresh")
        XCTAssertEqual(session.passageIndex(containing: 2), 0)
        XCTAssertEqual(session.passageIndex(containing: 3), 1)
        let full = ["the cat sat", "the cat"]
        let s = session.evaluate(MT.snapshot(full), settings: settings)
        XCTAssertEqual(MT.statuses(s), [.correct, .correct, .correct, .correct, .open, .pending, .pending])
        XCTAssertFalse(s.isComplete)
        // Edits on the new line never recolor the earlier one.
        for edited in [["the cat sat", "cat"], ["the cat sat", "the ca"], ["the cat sat", "the"]] {
            let t = session.evaluate(MT.snapshot(edited), settings: settings)
            XCTAssertEqual(Array(t.words.prefix(3)), Array(s.words.prefix(3)), "\(edited)")
        }
        XCTAssertEqual(session.passagesCompleted, 1)
        let done = session.evaluate(MT.snapshot(["the cat sat", "the cat ran off"]), settings: settings)
        XCTAssertTrue(done.isComplete)
        XCTAssertEqual(session.passagesCompleted, 2)
        XCTAssertEqual(session.result(duration: 60, mode: .oneMinute, settings: settings).totalWords, 7)

        session.reset()
        XCTAssertEqual(session.passages.map(\.id), ["test"], "Reset goes back to the first passage")
        XCTAssertEqual(session.firstAttempt, [nil, nil, nil])
    }
}
