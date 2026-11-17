import Foundation

/// Stateful matcher for one test: evaluates snapshots and remembers each
/// passage word's first lock-in outcome (first-attempt accuracy).
///
/// The "passage" matched against is the words of `passages` in order: one
/// passage, or the passages a timed test went through so far (`append`
/// adds one; the history of the words already there is kept).
///
/// First-attempt rules:
/// - A passage word's first attempt is recorded the first time it is aligned
///   to written content that is locked and not on a pending line (or when the
///   test completes, which settles the open last word too). It is correct
///   when the word is correct then, Vision-assisted included.
/// - A missed (skipped) word records a failed first attempt only in an
///   evaluation where a later passage word is settled; a merely transient
///   skip (only the open word is past it) records nothing.
/// - Records are never overwritten, even if the alignment later shifts and
///   different written content lands on the word (an accepted approximation).
///   The one exception: with Vision leniency on, a first attempt that failed
///   while the written word had no alternatives yet is upgraded to correct if
///   the same written word (same non-empty strokeIDs) later becomes correct
///   through its alternatives. If its alternatives arrive and do not help,
///   the chance is gone.
struct MatchSession {
    private(set) var passages: [Passage]
    private(set) var prepared: PreparedPassage
    /// Per passage: the end of its words in `prepared.words`.
    private(set) var passageEnds: [Int]

    /// Per passage word: nil until its first attempt is recorded.
    private(set) var firstAttempt: [Bool?]
    /// Per passage word: stroke IDs of a failed first attempt that Vision may
    /// still rescue.
    private var upgradeCandidate: [[UUID]?]
    private(set) var lastEvaluation: MatchEvaluation?
    private var cache: SubstitutionCache

    init(passage: Passage) {
        self.passages = [passage]
        self.prepared = PreparedPassage(passage: passage)
        self.passageEnds = [prepared.words.count]
        self.cache = SubstitutionCache(passage: prepared)
        self.firstAttempt = Array(repeating: nil, count: prepared.words.count)
        self.upgradeCandidate = Array(repeating: nil, count: prepared.words.count)
    }

    /// The passage the test started with.
    var passage: Passage { passages[0] }

    /// Back to the first passage with no history.
    mutating func reset() {
        if passages.count > 1 {
            self = MatchSession(passage: passage)
            return
        }
        firstAttempt = Array(repeating: nil, count: prepared.words.count)
        upgradeCandidate = Array(repeating: nil, count: prepared.words.count)
        lastEvaluation = nil
    }

    /// Continues the text with `next`. The words so far keep their history;
    /// the next evaluation covers the new words too. (Cached substitution
    /// rows span the whole text, so they are computed again, lazily.)
    mutating func append(_ next: Passage) {
        let words = next.words
        passages.append(next)
        prepared = PreparedPassage(words: prepared.words + words)
        passageEnds.append(prepared.words.count)
        cache = SubstitutionCache(passage: prepared)
        firstAttempt += Array(repeating: nil, count: words.count)
        upgradeCandidate += Array(repeating: nil, count: words.count)
        lastEvaluation = nil   // sized for the shorter text
    }

    /// The index in `passages` of the passage holding word `index`.
    func passageIndex(containing index: Int) -> Int {
        passageEnds.firstIndex { index < $0 } ?? passages.count - 1
    }

    /// Passages whose last word (with letters) is correct in the latest
    /// evaluation.
    var passagesCompleted: Int {
        guard let outcomes = lastEvaluation?.outcomes else { return 0 }
        var start = 0
        var done = 0
        for end in passageEnds {
            if let last = (start..<end).last(where: { !prepared.keys[$0].isEmpty }), outcomes[last].isCorrect { done += 1 }
            start = end
        }
        return done
    }

    var lastState: MatchState? { lastEvaluation?.state }

    mutating func evaluate(_ snapshot: WritingSnapshot, settings: SinglePlayerSettings) -> MatchState {
        let eval = MatchEvaluator.evaluate(snapshot, passage: prepared, settings: settings, cache: cache)
        record(eval, settings: settings)
        lastEvaluation = eval
        return eval.state
    }

    private mutating func record(_ eval: MatchEvaluation, settings: SinglePlayerSettings) {
        let count = prepared.words.count
        // Late Vision upgrades.
        for j in 0..<count {
            guard let ids = upgradeCandidate[j] else { continue }
            guard let written = eval.soleWritten[j], written.strokeIDs == ids,
                  !written.alternatives.isEmpty else { continue }
            if eval.outcomes[j] == .assisted && settings.visionLeniency { firstAttempt[j] = true }
            upgradeCandidate[j] = nil   // Vision has answered either way
        }

        // Is some later passage word settled? (suffix scan)
        var laterSettled = [Bool](repeating: false, count: count)
        var seen = false
        for j in stride(from: count - 1, through: 0, by: -1) {
            laterSettled[j] = seen
            if eval.settled[j] && eval.outcomes[j] != .missed { seen = true }
        }

        for j in 0..<count where firstAttempt[j] == nil {
            let outcome = eval.outcomes[j]
            if outcome == .missed {
                if laterSettled[j] { firstAttempt[j] = false }
            } else if eval.settled[j] && outcome != .pending {
                firstAttempt[j] = outcome.isCorrect
                if outcome == .incorrect, settings.visionLeniency, let w = eval.soleWritten[j],
                   w.alternatives.isEmpty, !w.strokeIDs.isEmpty {
                    upgradeCandidate[j] = w.strokeIDs
                }
            }
        }
    }

    /// Results from the latest evaluation (see `WordTally` for the formulas).
    func result(duration: TimeInterval, mode: TestMode, settings: SinglePlayerSettings) -> TestResult {
        tally().result(passage: passage, mode: mode, duration: duration,
                       passagesCompleted: passagesCompleted, settings: settings)
    }

    /// Word counts of the latest evaluation. `reachedOnly` stops after the
    /// last word with an outcome: a timed test counts only as far as it was
    /// written, not the untouched rest of its last passage.
    func tally(reachedOnly: Bool = false) -> WordTally {
        let words = prepared.words
        let count = words.count
        let outcomes = lastEvaluation?.outcomes ?? Array(repeating: .pending, count: count)
        let end = reachedOnly ? (outcomes.lastIndex { $0 != .pending } ?? -1) + 1 : count
        var t = WordTally(words: end)
        for j in 0..<end {
            let chars = words[j].count + (j < count - 1 ? 1 : 0)
            switch outcomes[j] {
            case .correct, .assisted:
                t.correct += 1
                t.correctChars += chars
                t.rawChars += chars
                if outcomes[j] == .assisted { t.assisted += 1 }
                if firstAttempt[j] == false { t.corrected += 1 }
            case .incorrect:
                t.rawChars += chars
            case .missed:
                t.missed += 1
            case .pending:
                break
            }
            if firstAttempt[j] == true { t.firstAttemptCorrect += 1 }
        }
        return t
    }
}

/// The word counts behind a `TestResult`.
///
/// - wpm: characters (passage word length incl. punctuation, plus one for
///   the following space except after the last word of the text) of
///   currently correct words / 5 per minute.
/// - rawWPM: same over correct + incorrect (attempted) words.
/// - accuracy: words whose first attempt was correct / words counted.
struct WordTally: Equatable, Sendable {
    /// Passage words counted (the accuracy denominator).
    var words = 0
    var correctChars = 0
    var rawChars = 0
    var correct = 0
    var firstAttemptCorrect = 0
    var corrected = 0
    var missed = 0
    var assisted = 0

    func wpm(duration: TimeInterval) -> Double { Self.perMinute(correctChars, duration) }

    func result(passage: Passage, mode: TestMode, duration: TimeInterval, passagesCompleted: Int,
                settings: SinglePlayerSettings) -> TestResult {
        TestResult(
            passage: passage, mode: mode, duration: max(0, duration),
            wpm: wpm(duration: duration), rawWPM: Self.perMinute(rawChars, duration),
            accuracy: words > 0 ? Double(firstAttemptCorrect) / Double(words) : 0,
            correctWords: correct, totalWords: words, wordsCorrected: corrected,
            missedWords: missed, assistedWords: assisted, passagesCompleted: passagesCompleted,
            visionLeniencyEnabled: settings.visionLeniency)
    }

    /// Monkeytype words per minute: characters / 5 per minute.
    private static func perMinute(_ chars: Int, _ duration: TimeInterval) -> Double {
        let minutes = duration / 60
        return minutes > 0 ? Double(chars) / 5 / minutes : 0
    }
}
