import Foundation

/// Per-character coloring of a passage word against what was written for it.
///
/// Letters: the passage word's normalized letters are aligned to the written
/// letters with a character-level Levenshtein alignment. A matched letter is
/// `.correct`; a substituted or missing passage letter is `.incorrect`. Extra
/// written letters have no passage character and are ignored.
///
/// Punctuation (any passage character that is not a letter or digit): if the
/// word is correct it is `.correct`; otherwise it takes the state of the
/// nearest preceding letter, or of the nearest following letter when it comes
/// before every letter (e.g. an opening quote).
enum LetterColoring {
    /// States of the passage letters `p` given written letters `w`.
    ///
    /// `live`: for the open word in live mode, only the first
    /// `min(w.count, p.count)` passage letters are compared (against all
    /// written letters); the rest are `.pending`. Wrong letters at the
    /// trailing edge (no correct letter after them yet) show as `.current`:
    /// a letter can read wrong mid-letter (the first stroke of "t" reads as
    /// "l") or be "completed" by the recognizer ("th" read as "the"), so it
    /// turns red only once a later letter is written or the word locks.
    static func letterStates(passage p: [MatchKeyCode], written w: [MatchKeyCode], live: Bool) -> [CharState] {
        let colored = live ? min(w.count, p.count) : p.count
        var states = [CharState](repeating: .pending, count: p.count)
        guard colored > 0 else { return states }
        if w.isEmpty {
            for i in 0..<colored { states[i] = .incorrect }
            return states
        }
        let rows = colored, cols = w.count
        let width = cols + 1
        var d = [Int](repeating: 0, count: (rows + 1) * width)
        for k in 0...cols { d[k] = k }
        for i in 1...rows {
            d[i * width] = i
            for k in 1...cols {
                let sub = d[(i - 1) * width + k - 1] + (p[i - 1] == w[k - 1] ? 0 : 1)
                let del = d[(i - 1) * width + k] + 1
                let ins = d[i * width + k - 1] + 1
                d[i * width + k] = min(sub, min(del, ins))
            }
        }
        var i = rows, k = cols
        while i > 0 {
            let here = d[i * width + k]
            if k > 0 {
                let eq = p[i - 1] == w[k - 1]
                if here == d[(i - 1) * width + k - 1] + (eq ? 0 : 1) {
                    states[i - 1] = eq ? .correct : .incorrect
                    i -= 1; k -= 1
                    continue
                }
            }
            if here == d[(i - 1) * width + k] + 1 {
                states[i - 1] = .incorrect   // passage letter missing
                i -= 1
                continue
            }
            k -= 1                           // extra written letter: ignored
        }
        if live {
            for i in stride(from: colored - 1, through: 0, by: -1) {
                guard states[i] == .incorrect else { break }
                states[i] = .current
            }
        }
        return states
    }

    /// Expands letter states to one state per Character of the passage word.
    /// `letterIndex[c]` is the letter index of character c, or nil for punctuation.
    static func charStates(letterIndex: [Int?], letters: [CharState], wordCorrect: Bool) -> [CharState] {
        if wordCorrect { return [CharState](repeating: .correct, count: letterIndex.count) }
        var out = [CharState](repeating: .pending, count: letterIndex.count)
        var previous: CharState?
        for (c, li) in letterIndex.enumerated() {
            if let li { previous = letters[li]; out[c] = letters[li] }
            else if let previous { out[c] = previous }
            else { out[c] = letters.first ?? .incorrect }
        }
        return out
    }
}
