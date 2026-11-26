import XCTest
@testable import MonkeyWrite

final class BundledPassagesTests: XCTestCase {
    private let passages = BundledPassages.all

    func testThirtyPassagesWithTenPerSubject() {
        XCTAssertEqual(passages.count, 30)
        for subject in PassageSubject.allCases {
            XCTAssertEqual(passages.filter { $0.subject == subject }.count, 10, subject.title)
        }
    }

    func testIdsAreUnique() {
        XCTAssertEqual(Set(passages.map(\.id)).count, passages.count)
    }

    func testSourcesAreNonEmpty() {
        for passage in passages {
            XCTAssertFalse(passage.source.trimmingCharacters(in: .whitespaces).isEmpty, passage.id)
        }
    }

    func testWordCountsAreInRange() {
        for passage in passages {
            XCTAssertTrue((40...50).contains(passage.words.count),
                          "\(passage.id) has \(passage.words.count) words")
        }
    }

    func testSimpleHandwritingPunctuation() {
        let forbidden = Set("\"“”;:-–—()0123456789")
        for passage in passages {
            let hits = passage.text.filter { forbidden.contains($0) }
            XCTAssertTrue(hits.isEmpty, "\(passage.id) contains \(hits)")
        }
    }

    func testWhitespaceIsNormalized() {
        for passage in passages {
            XCTAssertFalse(passage.text.contains("  "), passage.id)
            XCTAssertEqual(passage.text, passage.text.trimmingCharacters(in: .whitespacesAndNewlines), passage.id)
            XCTAssertFalse(passage.text.contains("\n") || passage.text.contains("\t"), passage.id)
        }
    }

    func testSubjectSelectionScopesTheEntirePool() {
        for subject in PassageSubject.allCases {
            let source = BundledPassages(subject: subject, defaults: temporaryDefaults())
            XCTAssertEqual(source.allPassages().count, 10)
            XCTAssertTrue(source.allPassages().allSatisfy { $0.subject == subject })
            for passage in source.allPassages() {
                for _ in 0..<20 {
                    let next = source.nextPassage(excluding: [passage.id])
                    XCTAssertEqual(next.subject, subject)
                    XCTAssertNotEqual(next.id, passage.id)
                }
            }
        }
    }

    func testUnfilteredSourcePreservesAllPassages() {
        let source = BundledPassages(defaults: temporaryDefaults())
        XCTAssertEqual(source.allPassages(), passages)
        for passage in passages {
            XCTAssertNotEqual(source.nextPassage(excluding: [passage.id]).id, passage.id)
        }
    }

    func testOlderCallersCanCreateUncategorizedPassages() {
        let passage = Passage(id: "custom", text: "A custom passage.", source: "Custom")
        XCTAssertNil(passage.subject)
    }
}
