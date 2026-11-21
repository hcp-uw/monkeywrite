import Foundation

// Shared types for the single-player round. Ink, Matching, UI and Results all
// code against these, so each area can change independently.

// MARK: - Passages and modes

enum PassageSubject: String, CaseIterable, Identifiable, Sendable {
    case biology
    case history
    case computerScience

    var id: Self { self }

    var title: String {
        switch self {
        case .biology: "Biology"
        case .history: "History"
        case .computerScience: "Computer Science"
        }
    }
}

struct Passage: Identifiable, Equatable, Sendable {
    let id: String
    /// The text shown in the display, exactly as written (case and punctuation kept).
    let text: String
    /// Attribution shown in small print.
    let source: String
    /// Optional so existing callers can still provide uncategorized passages.
    let subject: PassageSubject?

    init(id: String, text: String, source: String, subject: PassageSubject? = nil) {
        self.id = id
        self.text = text
        self.source = source
        self.subject = subject
    }

    /// The passage split on whitespace. Index i is "passage word i" everywhere.
    var words: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
}

/// Where passages come from. Later: a user picker, random words, etc.
protocol PassageSource {
    func allPassages() -> [Passage]
    /// The next passage to show: none of `excluding` (the passages on screen,
    /// most recent last) when possible, otherwise not the most recent one.
    func nextPassage(excluding: [Passage.ID]) -> Passage
}

enum TestMode: Hashable, Sendable {
    /// Write the whole passage; the test ends when its last word is correct.
    case passage
    /// Write as much as possible in a fixed time. The clock starts at the
    /// first stroke; each completed passage is followed by another one on
    /// fresh paper until time is up.
    case timed(seconds: Int)

    static let oneMinute = TestMode.timed(seconds: 60)
    /// The modes offered in the UI.
    static let choices: [TestMode] = [.oneMinute, .passage]

    var title: String {
        switch self {
        case .passage: "Passage"
        case let .timed(seconds): "\(seconds) Seconds"
        }
    }

    var symbol: String { self == .passage ? "text.alignleft" : "timer" }

    var description: String {
        switch self {
        case .passage: "Practice your skills on a simple passage"
        case let .timed(seconds): "Write as much as you can in \(seconds) seconds."
        }
    }
}

/// Stored as "passage" or "timed:<seconds>" (the settings and the home
/// screen share one UserDefaults key, see `SettingsStorage.modeKey`).
extension TestMode: RawRepresentable {
    init?(rawValue: String) {
        if rawValue == "passage" {
            self = .passage
        } else if rawValue.hasPrefix("timed:"), let seconds = Int(rawValue.dropFirst(6)), seconds > 0 {
            self = .timed(seconds: seconds)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .passage: "passage"
        case let .timed(seconds): "timed:\(seconds)"
        }
    }
}

// MARK: - Recognized handwriting (Ink/Recognition -> Matching)

/// One word as recognized on the paper.
struct WrittenWord: Equatable, Sendable {
    /// Recognizer text for this word, unchanged (case/punctuation intact).
    var text: String
    /// Strokes that make up the word, in drawing order. May be empty if the
    /// stroke grouping could not be determined.
    var strokeIDs: [UUID]
    /// Ranked alternative readings (Vision OCR top candidates), best first.
    /// Empty unless Vision leniency ran for this word.
    var alternatives: [String] = []
}

/// The recognized content of one paper line.
struct WrittenLine: Equatable, Sendable {
    /// Zero-based paper line index (0 = top rule).
    var index: Int
    /// Words left to right.
    var words: [WrittenWord]
}

/// Everything the matcher needs for one evaluation.
struct WritingSnapshot: Equatable, Sendable {
    /// Lines that have strokes, ordered by `index`. Words are read in this
    /// order: line by line, left to right.
    var lines: [WrittenLine]
    /// The paper line the most recent stroke landed on, if any. One word on
    /// this line is the "open" word (still being written); every other word
    /// is locked. Nil locks every word.
    var activeLineIndex: Int?
    /// The most recent stroke (last in drawing order). The open word is the
    /// word on the active line whose `strokeIDs` contain it, so a word being
    /// rewritten mid-line is the open one; when no word contains it (unknown
    /// grouping, or nil), it is the last word on the active line.
    var activeStrokeID: UUID? = nil
    /// Lines whose strokes are recognized but whose recognition is not
    /// current yet (an edit is still being analyzed). Their words are not
    /// first-attempt-recorded until current.
    var pendingLineIndices: Set<Int> = []
}

// MARK: - Match result (Matching -> UI)

enum CharState: Equatable, Sendable {
    case pending     // not written yet
    case current     // part of the open word in neutral coloring mode
    case correct
    case incorrect
}

enum WordStatus: Equatable, Sendable {
    case pending     // nothing written for it yet
    case open        // being written (the open word)
    case correct
    case incorrect
    case missed      // skipped: later words were written but not this one
}

struct WordMatch: Equatable, Sendable {
    var status: WordStatus
    /// One state per Character of the passage word (punctuation included).
    var chars: [CharState]
    /// True when it is correct only because a Vision alternative matched.
    var assisted: Bool = false
}

struct MatchState: Equatable, Sendable {
    /// One entry per passage word.
    var words: [WordMatch]
    /// Index of the furthest passage word reached: the open word's passage
    /// index, else the first pending word after the last written one.
    /// The display centers the line containing this word.
    var cursorWordIndex: Int
    /// The last passage word is correct: the test is complete.
    var isComplete: Bool
    /// Locked written words aligned to an incorrect passage word whose
    /// Vision alternatives were not checked yet (only meaningful when Vision
    /// leniency is on). Identified by their stroke IDs.
    var wordsNeedingVision: [[UUID]] = []
}

// MARK: - Results (Matching/Session -> Results UI, owned by the stats teammate)

struct TestResult: Equatable, Sendable {
    /// The passage the test started with (a timed test may go on to others).
    var passage: Passage
    var mode: TestMode
    /// Touch-down of the first stroke to the end of the last stroke; the
    /// full time of a timed test.
    var duration: TimeInterval
    /// Monkeytype: characters of correct words incl. spaces / 5, per minute.
    var wpm: Double
    /// Same as wpm but counts incorrect (attempted) words too.
    var rawWPM: Double
    /// First-attempt word accuracy, 0...1.
    var accuracy: Double
    var correctWords: Int
    /// The passage's words; in a timed test, the words of every completed
    /// passage plus those reached in the last one.
    var totalWords: Int
    /// Words that were wrong on first lock-in and were later fixed.
    var wordsCorrected: Int
    var missedWords: Int
    /// Words accepted only thanks to Vision leniency.
    var assistedWords: Int
    /// Passages whose last word was written correctly (at most 1 in passage mode).
    var passagesCompleted: Int
    var visionLeniencyEnabled: Bool
}

// MARK: - Settings

enum WordColoringMode: String, CaseIterable, Identifiable, Sendable {
    /// The word being written stays neutral until it locks.
    case neutralUntilLocked
    /// The word being written is colored letter by letter as you go.
    case live

    var id: Self { self }
    var title: String { self == .live ? "Live" : "When word is done" }
}

struct SinglePlayerSettings: Equatable, Sendable {
    static let visibleLineRange = 3...8

    var mode = TestMode.oneMinute
    /// Paper lines visible at once. Takes effect on the next test.
    var visibleLines = 5
    var coloring = WordColoringMode.live
    /// Use Vision OCR's top candidates to accept a misread word.
    var visionLeniency = false
    /// How many of Vision's ranked candidates may rescue a word.
    var visionCandidateLimit = 3
    var showLiveStats = true
    /// When on, one finger draws and two fingers scroll the paper.
    var fingerWriting = false
    /// After an eraser gesture that erased something, the tool goes back to
    /// the pen when the pencil lifts.
    var autoSwitchToPen = true
    /// Shows what the recognizer read under the live stats (for diagnosis).
    var showDebugInfo = false
}

