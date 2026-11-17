import Foundation
@testable import MonkeyWrite

/// Builders for matching tests.
enum MT {
    static func passage(_ text: String) -> Passage {
        Passage(id: "test", text: text, source: "Test")
    }

    static func word(_ text: String, alternatives: [String] = [], ids: [UUID]? = nil) -> WrittenWord {
        WrittenWord(text: text, strokeIDs: ids ?? [UUID()], alternatives: alternatives)
    }

    /// Lines of space-separated text, line i gets paper index i.
    /// `active` defaults to the last line.
    static func snapshot(_ lines: [String], active: Int?? = .none, pending: Set<Int> = []) -> WritingSnapshot {
        let written = lines.enumerated().map { i, text in
            WrittenLine(index: i, words: text.split(separator: " ").map { word(String($0)) })
        }
        let activeLine: Int?
        switch active {
        case .none: activeLine = lines.isEmpty ? nil : lines.count - 1
        case .some(let a): activeLine = a
        }
        return WritingSnapshot(lines: written, activeLineIndex: activeLine, pendingLineIndices: pending)
    }

    static func snapshot(words: [[WrittenWord]], active: Int?, pending: Set<Int> = []) -> WritingSnapshot {
        WritingSnapshot(lines: words.enumerated().map { WrittenLine(index: $0.offset, words: $0.element) },
                        activeLineIndex: active, pendingLineIndices: pending)
    }

    static func settings(coloring: WordColoringMode = .neutralUntilLocked, vision: Bool = false) -> SinglePlayerSettings {
        var s = SinglePlayerSettings()
        s.coloring = coloring
        s.visionLeniency = vision
        return s
    }

    static func evaluate(_ text: String, _ lines: [String], active: Int?? = .none,
                         settings: SinglePlayerSettings = MT.settings()) -> MatchState {
        var session = MatchSession(passage: passage(text))
        return session.evaluate(snapshot(lines, active: active), settings: settings)
    }

    static func statuses(_ state: MatchState) -> [WordStatus] { state.words.map(\.status) }
}
