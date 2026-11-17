import Foundation

/// The passage, precomputed once for repeated evaluation.
struct PreparedPassage: Equatable, Sendable {
    let words: [String]
    let keys: [[MatchKeyCode]]
    /// Per word, per Character: index into the word's key, or nil for punctuation.
    let letterIndex: [[Int?]]
    /// Passage indices whose key is non-empty (they take part in alignment).
    let alignable: [Int]

    init(words: [String]) {
        self.words = words
        var keys: [[MatchKeyCode]] = []
        var letterIndex: [[Int?]] = []
        for word in words {
            var key: [MatchKeyCode] = []
            var map: [Int?] = []
            for ch in word {
                if let code = MatchKey.code(for: ch) { map.append(key.count); key.append(code) }
                else { map.append(nil) }
            }
            keys.append(key)
            letterIndex.append(map)
        }
        self.keys = keys
        self.letterIndex = letterIndex
        self.alignable = keys.indices.filter { !keys[$0].isEmpty }
    }

    init(passage: Passage) { self.init(words: passage.words) }
}

/// Caches each written key's substitution-cost row against one passage, so
/// re-evaluating a snapshot only computes rows for new or changed words.
/// Pure function of its inputs, so sharing it between copies is harmless.
final class SubstitutionCache {
    let table: PassageAligner.KeyTable
    private var rows: [[MatchKeyCode]: [Double]] = [:]
    static let capacity = 4096

    init(passage: PreparedPassage) {
        table = PassageAligner.KeyTable(passage.alignable.map { passage.keys[$0] })
    }

    func row(for key: [MatchKeyCode]) -> [Double] {
        if let r = rows[key] { return r }
        if rows.count >= Self.capacity { rows.removeAll(keepingCapacity: true) }
        let r = PassageAligner.substitutionRow(written: key, passage: table)
        rows[key] = r
        return r
    }

    /// Row-major matrix for `keys`.
    func matrix(for keys: [[MatchKeyCode]]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(keys.count * table.start.count)
        for k in keys { out.append(contentsOf: row(for: k)) }
        return out
    }
}

/// How a passage word currently stands, treating the open word as if it were
/// locked. Used for results and first-attempt history.
enum WordOutcome: Equatable, Sendable {
    case pending, correct, assisted, incorrect, missed

    var isCorrect: Bool { self == .correct || self == .assisted }
}

/// One evaluation: the UI state plus the details the session needs.
struct MatchEvaluation: Equatable, Sendable {
    var state: MatchState
    /// Per passage word.
    var outcomes: [WordOutcome]
    /// Per passage word: aligned only to written words that are locked and not
    /// on a pending line (or the test is complete). Eligible for first-attempt
    /// recording.
    var settled: [Bool]
    /// Per passage word: the single written word aligned to it by match or
    /// substitution, if any.
    var soleWritten: [WrittenWord?]
}

/// Pure, stateless evaluation of a snapshot against a passage.
enum MatchEvaluator {
    private struct Entry {
        var word: WrittenWord
        var key: [MatchKeyCode]
        var isOpen: Bool
        var onPendingLine: Bool
    }

    private struct Assignment {
        var entries: [Int]
        var key: [MatchKeyCode]
        /// Match or substitution of one written word (Vision may rescue it).
        var single: Bool
    }

    static func evaluate(_ snapshot: WritingSnapshot, passage: PreparedPassage,
                         settings: SinglePlayerSettings, cache: SubstitutionCache? = nil) -> MatchEvaluation {
        let count = passage.words.count

        // 1. Written words in reading order; drop those with empty keys.
        let lines = snapshot.lines.sorted { $0.index < $1.index }
        var entries: [Entry] = []
        entries.reserveCapacity(lines.reduce(0) { $0 + $1.words.count })
        // The open word: the (non-empty) word on the active line holding the
        // newest stroke, else the line's last word. Also noted: how many
        // entries precede the newest stroke, for when no open word can be
        // aligned (see step 6).
        var lastOnActiveLine: Int?, holdingNewestStroke: Int?
        var entriesBeforeHolder: Int?, entriesBeforeLaterLines: Int?
        for line in lines {
            if let active = snapshot.activeLineIndex, line.index > active, entriesBeforeLaterLines == nil {
                entriesBeforeLaterLines = entries.count
            }
            let pending = snapshot.pendingLineIndices.contains(line.index)
            for word in line.words {
                let key = MatchKey.key(word.text)
                let holds = line.index == snapshot.activeLineIndex
                    && snapshot.activeStrokeID.map(word.strokeIDs.contains) == true
                if holds { entriesBeforeHolder = entries.count }
                if key.isEmpty { continue }
                if line.index == snapshot.activeLineIndex {
                    lastOnActiveLine = entries.count
                    if holds { holdingNewestStroke = entries.count }
                }
                entries.append(Entry(word: word, key: key, isOpen: false, onPendingLine: pending))
            }
        }
        // A holder that reads as punctuation only is the open word too, just
        // not an entry.
        let openEntry = entriesBeforeHolder != nil ? holdingNewestStroke : lastOnActiveLine
        if let openEntry { entries[openEntry].isOpen = true }

        // 2. Align.
        let pKeys = passage.alignable.map { passage.keys[$0] }
        let wKeys = entries.map(\.key)
        let ops = PassageAligner.alignKeys(written: wKeys, passage: pKeys, openWritten: openEntry,
                                           substitutionCosts: cache?.matrix(for: wKeys))

        var assignment = [Assignment?](repeating: nil, count: count)
        var missed = [Bool](repeating: false, count: count)
        var openAligned = false
        for op in ops {
            switch op {
            case let .match(w, _), let .substitute(w, _), let .split(w, _):
                if w == openEntry { openAligned = true }
            case let .merge(a, b, _):
                if a == openEntry || b == openEntry { openAligned = true }
            case .skip, .extra:
                break
            }
            switch op {
            case let .match(w, p), let .substitute(w, p):
                assignment[passage.alignable[p]] = Assignment(entries: [w], key: entries[w].key, single: true)
            case let .merge(a, b, p):
                assignment[passage.alignable[p]] = Assignment(entries: [a, b], key: entries[a].key + entries[b].key, single: false)
            case let .split(w, p):
                let first = passage.alignable[p], second = passage.alignable[p + 1]
                let key = entries[w].key
                let cut = passage.keys[first].count
                assignment[first] = Assignment(entries: [w], key: Array(key[..<cut]), single: false)
                assignment[second] = Assignment(entries: [w], key: Array(key[cut...]), single: false)
            case let .skip(p):
                missed[passage.alignable[p]] = true
            case .extra:
                break
            }
        }

        // 3. Per-word state.
        let limit = max(0, settings.visionCandidateLimit)
        var words = [WordMatch](repeating: WordMatch(status: .pending, chars: []), count: count)
        var outcomes = [WordOutcome](repeating: .pending, count: count)
        var settled = [Bool](repeating: false, count: count)
        var sole = [WrittenWord?](repeating: nil, count: count)
        var isOpenWord = [Bool](repeating: false, count: count)
        var needingVision: [[UUID]] = []
        var visionSeen = Set<Int>()
        var lastLocked = -1, lastOpen = -1

        for j in 0..<count {
            let pKey = passage.keys[j]
            let map = passage.letterIndex[j]
            if let a = assignment[j] {
                let open = a.entries.contains { entries[$0].isOpen }
                let written = a.single ? entries[a.entries[0]].word : nil
                sole[j] = written
                var outcome: WordOutcome = a.key == pKey ? .correct : .incorrect
                if outcome == .incorrect, settings.visionLeniency, let written,
                   written.alternatives.prefix(limit).contains(where: { MatchKey.key($0) == pKey }) {
                    outcome = .assisted
                }
                outcomes[j] = outcome
                settled[j] = !open && a.entries.allSatisfy { !entries[$0].onPendingLine }
                if open {
                    isOpenWord[j] = true
                    lastOpen = j
                    switch settings.coloring {
                    case .neutralUntilLocked:
                        words[j] = WordMatch(status: .open, chars: Array(repeating: .current, count: map.count))
                    case .live:
                        let letters = LetterColoring.letterStates(passage: pKey, written: a.key, live: true)
                        words[j] = WordMatch(status: .open, chars: LetterColoring.charStates(letterIndex: map, letters: letters, wordCorrect: false))
                    }
                } else {
                    lastLocked = j
                    switch outcome {
                    case .correct, .assisted:
                        words[j] = WordMatch(status: .correct, chars: Array(repeating: .correct, count: map.count),
                                             assisted: outcome == .assisted)
                    default:
                        let letters = LetterColoring.letterStates(passage: pKey, written: a.key, live: false)
                        words[j] = WordMatch(status: .incorrect, chars: LetterColoring.charStates(letterIndex: map, letters: letters, wordCorrect: false))
                        if settings.visionLeniency, let written, written.alternatives.isEmpty,
                           !written.strokeIDs.isEmpty, visionSeen.insert(a.entries[0]).inserted {
                            needingVision.append(written.strokeIDs)
                        }
                    }
                }
            } else if missed[j] {
                outcomes[j] = .missed
                words[j] = WordMatch(status: .missed, chars: Array(repeating: .incorrect, count: map.count))
            } else {
                words[j] = WordMatch(status: .pending, chars: Array(repeating: .pending, count: map.count))
            }
        }

        // 4. Completion: the last alignable passage word is correct (open or locked).
        var complete = false
        if let last = passage.alignable.last, outcomes[last].isCorrect { complete = true }
        if complete {
            // The round ends: show open words as locked and let history record them.
            for j in 0..<count where isOpenWord[j] {
                settled[j] = true
                if outcomes[j].isCorrect {
                    words[j] = WordMatch(status: .correct, chars: Array(repeating: .correct, count: passage.letterIndex[j].count),
                                         assisted: outcomes[j] == .assisted)
                } else {
                    let letters = LetterColoring.letterStates(passage: passage.keys[j], written: assignment[j]!.key, live: false)
                    words[j] = WordMatch(status: .incorrect, chars: LetterColoring.charStates(letterIndex: passage.letterIndex[j], letters: letters, wordCorrect: false))
                }
            }
            for j in 0..<count where assignment[j] != nil { settled[j] = true }
        }

        // 5. Passage words with no letters (e.g. a lone "—"): punctuation is
        // optional, so they are correct once a later word is reached (or the
        // test is complete), pending otherwise.
        var laterReached = complete
        for j in stride(from: count - 1, through: 0, by: -1) {
            if passage.keys[j].isEmpty {
                if laterReached {
                    outcomes[j] = .correct
                    settled[j] = true
                    words[j] = WordMatch(status: .correct, chars: Array(repeating: .correct, count: passage.letterIndex[j].count))
                }
            } else if outcomes[j] != .pending {
                laterReached = true
            }
        }

        // 6. Writing is under way but no open word was aligned: the newest
        // stroke's line has no recognition yet, its word reads as punctuation
        // only, or it aligned as an extra. Underline the passage word expected
        // there instead, the one after the last passage word aligned to an
        // entry before the stroke, neutrally: nothing is recognized for it, so
        // it stays pending for history and results.
        if snapshot.activeLineIndex != nil, !openAligned, !complete {
            let before = openEntry ?? entriesBeforeHolder ?? entriesBeforeLaterLines ?? entries.count
            var lastBefore = -1   // index into `passage.alignable`
            for op in ops {
                switch op {
                case let .match(w, p), let .substitute(w, p), let .merge(_, w, p):
                    if w < before { lastBefore = max(lastBefore, p) }
                case let .split(w, p):
                    if w < before { lastBefore = max(lastBefore, p + 1) }
                case .skip, .extra:
                    break
                }
            }
            if lastBefore + 1 < passage.alignable.count {
                let j = passage.alignable[lastBefore + 1]
                if assignment[j] == nil {
                    outcomes[j] = .pending
                    settled[j] = false
                    words[j] = WordMatch(status: .open, chars: Array(repeating: .current, count: passage.letterIndex[j].count))
                    lastOpen = max(lastOpen, j)
                }
            }
        }

        // 7. Cursor: furthest progress (not the word being fixed).
        var cursor = max(lastLocked + 1, lastOpen)
        cursor = count == 0 ? 0 : min(max(cursor, 0), count - 1)

        let state = MatchState(words: words, cursorWordIndex: cursor, isComplete: complete,
                               wordsNeedingVision: needingVision)
        return MatchEvaluation(state: state, outcomes: outcomes, settled: settled, soleWritten: sole)
    }
}
