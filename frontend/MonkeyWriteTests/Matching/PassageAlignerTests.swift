import XCTest
@testable import MonkeyWrite

final class PassageAlignerTests: XCTestCase {
    private func words(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    func testNormalization() {
        XCTAssertEqual(MatchKey.normalized("Holmes,"), "holmes")
        XCTAssertEqual(MatchKey.key("Don't"), MatchKey.key("dont"))
        XCTAssertEqual(MatchKey.key("\u{201C}Well\u{2019}s\u{201D}"), MatchKey.key("wells"))
        XCTAssertEqual(MatchKey.key("THE"), MatchKey.key("the"))
        XCTAssertTrue(MatchKey.key("—").isEmpty)
        XCTAssertTrue(MatchKey.key(",").isEmpty)
        // Precomposed and decomposed accents compare equal; accents still count.
        XCTAssertEqual(MatchKey.key("caf\u{E9}"), MatchKey.key("cafe\u{301}"))
        XCTAssertNotEqual(MatchKey.key("café"), MatchKey.key("cafe"))
    }

    func testExactMatch() {
        XCTAssertEqual(PassageAligner.align(written: words("the cat sat"), passage: words("the cat sat")),
                       [.match(written: 0, passage: 0), .match(written: 1, passage: 1), .match(written: 2, passage: 2)])
    }

    func testCaseAndPunctuationMatch() {
        let ops = PassageAligner.align(written: words("the holmes dont"), passage: words("The Holmes, don't"))
        XCTAssertEqual(ops, [.match(written: 0, passage: 0), .match(written: 1, passage: 1), .match(written: 2, passage: 2)])
    }

    func testMisspellingSubstitutes() {
        XCTAssertEqual(PassageAligner.align(written: words("the cta sat"), passage: words("the cat sat")),
                       [.match(written: 0, passage: 0), .substitute(written: 1, passage: 1), .match(written: 2, passage: 2)])
        // Also at the trailing edge (free end gap must not turn it into an extra).
        XCTAssertEqual(PassageAligner.align(written: words("the cta"), passage: words("the cat sat")),
                       [.match(written: 0, passage: 0), .substitute(written: 1, passage: 1)])
    }

    func testSkippedWord() {
        XCTAssertEqual(PassageAligner.align(written: words("the sat on"), passage: words("the cat sat on")),
                       [.match(written: 0, passage: 0), .skip(passage: 1), .match(written: 1, passage: 2), .match(written: 2, passage: 3)])
        // Trailing: "a c" against "a b c".
        XCTAssertEqual(PassageAligner.align(written: words("a c"), passage: words("a b c")),
                       [.match(written: 0, passage: 0), .skip(passage: 1), .match(written: 1, passage: 2)])
    }

    func testExtraWord() {
        XCTAssertEqual(PassageAligner.align(written: words("the big cat sat"), passage: words("the cat sat")),
                       [.match(written: 0, passage: 0), .extra(written: 1), .match(written: 2, passage: 1), .match(written: 3, passage: 2)])
    }

    func testMergeAndSplit() {
        XCTAssertEqual(PassageAligner.align(written: words("see you to day"), passage: words("see you today")),
                       [.match(written: 0, passage: 0), .match(written: 1, passage: 1), .merge(first: 2, second: 3, passage: 2)])
        XCTAssertEqual(PassageAligner.align(written: words("end ofthe day"), passage: words("end of the day")),
                       [.match(written: 0, passage: 0), .split(written: 1, firstPassage: 1), .match(written: 2, passage: 3)])
    }

    func testTrailingPassageWordsHaveNoOps() {
        XCTAssertEqual(PassageAligner.align(written: words("the cat"), passage: words("the cat sat on the mat")),
                       [.match(written: 0, passage: 0), .match(written: 1, passage: 1)])
        XCTAssertEqual(PassageAligner.align(written: [], passage: words("a b")), [])
    }

    func testWrittenBeyondEndIsExtra() {
        XCTAssertEqual(PassageAligner.align(written: words("the end and more"), passage: words("the end")),
                       [.match(written: 0, passage: 0), .match(written: 1, passage: 1), .extra(written: 2), .extra(written: 3)])
    }

    func testEmptyKeysProduceNoOps() {
        XCTAssertEqual(PassageAligner.align(written: ["the", ",", "cat"], passage: ["the", "—", "cat"]),
                       [.match(written: 0, passage: 0), .match(written: 2, passage: 2)])
    }

    func testRepeatedWordsPreferInOrder() {
        XCTAssertEqual(PassageAligner.align(written: words("the the"), passage: words("the the the")),
                       [.match(written: 0, passage: 0), .match(written: 1, passage: 1)])
    }

    func testPerformance80x80() {
        let vocab = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "holmes", "watson",
                     "street", "baker", "remarkable", "evening", "letter"]
        let passage = (0..<80).map { vocab[($0 * 7) % vocab.count] }
        // Written: a few misspellings, a skip and an extra.
        var written = passage
        written[10] = "quikc"; written[30] = "hlomes"; written.remove(at: 50); written.insert("um", at: 60)
        let pKeys = passage.map(MatchKey.key), wKeys = written.map(MatchKey.key)
        _ = PassageAligner.alignKeys(written: wKeys, passage: pKeys)   // warm-up
        let runs = 20
        let start = Date()
        for _ in 0..<runs { _ = PassageAligner.alignKeys(written: wKeys, passage: pKeys) }
        let ms = Date().timeIntervalSince(start) * 1000 / Double(runs)
        print("MATCHING_PERF alignKeys 80x80: \(String(format: "%.3f", ms)) ms/run")

        let s1 = Date()
        let pt = PassageAligner.KeyTable(pKeys), wt = PassageAligner.KeyTable(wKeys)
        for _ in 0..<runs { _ = PassageAligner.substitutionMatrix(written: wt, passage: pt) }
        let msSub = Date().timeIntervalSince(s1) * 1000 / Double(runs)
        print("MATCHING_PERF substitutionMatrix 80x80: \(String(format: "%.3f", msSub)) ms/run")

        // Full evaluation incl. normalization and coloring.
        let session = MatchSession(passage: MT.passage(passage.joined(separator: " ")))
        let snap = MT.snapshot([written.joined(separator: " ")])
        let s2 = Date()
        for _ in 0..<runs { _ = MatchEvaluator.evaluate(snap, passage: session.prepared, settings: MT.settings(coloring: .live)) }
        let ms2 = Date().timeIntervalSince(s2) * 1000 / Double(runs)
        print("MATCHING_PERF evaluate 80x80: \(String(format: "%.3f", ms2)) ms/run")

        // Typical incremental case: the session caches rows of unchanged words.
        var cached = MatchSession(passage: MT.passage(passage.joined(separator: " ")))
        _ = cached.evaluate(snap, settings: MT.settings(coloring: .live))
        var grown = written; grown[grown.count - 1] += "x"
        let snap2 = MT.snapshot([grown.joined(separator: " ")])
        let s3 = Date()
        for k in 0..<runs { _ = cached.evaluate(k % 2 == 0 ? snap2 : snap, settings: MT.settings(coloring: .live)) }
        let ms3 = Date().timeIntervalSince(s3) * 1000 / Double(runs)
        print("MATCHING_PERF session.evaluate 80x80 (cached rows): \(String(format: "%.3f", ms3)) ms/run")
        XCTAssertEqual(cached.evaluate(snap2, settings: MT.settings()),
                       MatchEvaluator.evaluate(snap2, passage: cached.prepared, settings: MT.settings()).state,
                       "cache must not change results")
        XCTAssertLessThan(ms2, 1000)   // sanity only; timing is logged, not asserted tightly
    }
}
