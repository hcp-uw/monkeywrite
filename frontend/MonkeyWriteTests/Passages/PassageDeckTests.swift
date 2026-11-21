import XCTest
@testable import MonkeyWrite

final class PassageDeckTests: XCTestCase {
    private let pool = (0..<10).map { "p\($0)" }

    func testEveryPassageIsDealtOnceBeforeAnyRepeat() {
        let deck = PassageDeck(name: "t", defaults: temporaryDefaults())
        for _ in 0..<20 {
            let round = (0..<pool.count).compactMap { _ in deck.deal(from: pool, excluding: []) }
            XCTAssertEqual(Set(round), Set(pool))
        }
    }

    func testNoBackToBackRepeatAcrossRefills() {
        let deck = PassageDeck(name: "t", defaults: temporaryDefaults())
        var previous: String?
        for _ in 0..<500 {
            let id = deck.deal(from: pool, excluding: [])
            XCTAssertNotEqual(id, previous)
            previous = id
        }
    }

    func testRefillNeverStartsWithTheLastPassageDealt() {
        // First bag in order (p9 dealt last), then a refill that puts p9 first.
        var shuffles = 0
        let deck = PassageDeck(name: "t", defaults: temporaryDefaults(), shuffle: { ids in
            shuffles += 1
            return shuffles == 1 ? ids : ids.reversed()
        })
        let first = (0..<pool.count).compactMap { _ in deck.deal(from: pool, excluding: []) }
        XCTAssertEqual(first, pool)
        XCTAssertEqual(deck.deal(from: pool, excluding: []), "p8", "p9 was dealt last, so it is skipped")
        let rest = (0..<9).compactMap { _ in deck.deal(from: pool, excluding: []) }
        XCTAssertEqual(Set(rest + ["p8"]), Set(pool), "The skipped p9 is still dealt in this bag")
    }

    func testExcludedPassagesAreSkippedAndStayInTheBag() {
        let deck = PassageDeck(name: "t", defaults: temporaryDefaults(), shuffle: { $0 })
        XCTAssertEqual(deck.deal(from: pool, excluding: ["p0", "p1"]), "p2")
        let rest = (0..<9).compactMap { _ in deck.deal(from: pool, excluding: []) }
        XCTAssertEqual(Set(rest), Set(pool).subtracting(["p2"]), "p0 and p1 were still dealt in this bag")
    }

    func testOnScreenLeftoversAreDealtBeforeTheNextCycle() {
        let deck = PassageDeck(name: "t", defaults: temporaryDefaults(), shuffle: { $0 })
        let first = (0..<8).compactMap { _ in deck.deal(from: pool, excluding: []) }
        XCTAssertEqual(first, Array(pool[0..<8]))
        // p8 and p9 are left, both on screen: a new cycle starts early...
        XCTAssertEqual(deck.deal(from: pool, excluding: ["p8", "p9"]), "p0")
        // ...but p8 and p9 still come next, before the rest of that cycle.
        XCTAssertEqual(deck.deal(from: pool, excluding: []), "p8")
        XCTAssertEqual(deck.deal(from: pool, excluding: []), "p9")
    }

    func testAllExcludedFallsBackToNotTheMostRecent() {
        let deck = PassageDeck(name: "t", defaults: temporaryDefaults())
        let small = ["a", "b"]
        for _ in 0..<20 {
            XCTAssertEqual(deck.deal(from: small, excluding: ["a", "b"]), "a")
            XCTAssertEqual(deck.deal(from: small, excluding: ["b", "a"]), "b")
        }
    }

    func testBagPersistsAcrossInstances() {
        let defaults = temporaryDefaults()
        let a = PassageDeck(name: "t", defaults: defaults)
        let firstFour = (0..<4).compactMap { _ in a.deal(from: pool, excluding: []) }
        let b = PassageDeck(name: "t", defaults: defaults)
        let lastSix = (0..<6).compactMap { _ in b.deal(from: pool, excluding: []) }
        XCTAssertEqual(Set(firstFour + lastSix), Set(pool))
    }

    func testStaleIdsAreDropped() {
        let defaults = temporaryDefaults()
        defaults.set(["gone", "p3"], forKey: SettingsStorage.prefix + "passageDeck.t.bag")
        let deck = PassageDeck(name: "t", defaults: defaults)
        XCTAssertEqual(deck.deal(from: pool, excluding: []), "p3", "The stale ID is skipped")
    }

    func testEmptyPoolDealsNothing() {
        XCTAssertNil(PassageDeck(name: "t", defaults: temporaryDefaults()).deal(from: [], excluding: []))
    }

    // MARK: BundledPassages

    func testSubjectsHaveSeparateBags() {
        let defaults = temporaryDefaults()
        let biology = BundledPassages(subject: .biology, defaults: defaults)
        let history = BundledPassages(subject: .history, defaults: defaults)
        var seen: [String] = []
        for _ in 0..<5 {
            seen.append(biology.nextPassage(excluding: []).id)
            _ = history.nextPassage(excluding: [])
        }
        for _ in 0..<5 { seen.append(biology.nextPassage(excluding: []).id) }
        XCTAssertEqual(Set(seen).count, 10, "History deals do not use up the biology bag")
    }

    func testRoundsAcrossNewSourcesCoverTheSubject() {
        let defaults = temporaryDefaults()
        // Each Start Round makes a new source; the bag carries over.
        let ids = (0..<10).map { _ in
            BundledPassages(subject: .computerScience, defaults: defaults).nextPassage(excluding: []).id
        }
        XCTAssertEqual(Set(ids).count, 10)
    }
}
