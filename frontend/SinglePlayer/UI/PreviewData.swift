#if DEBUG
import SwiftUI

enum PreviewData {
    static let passage = BundledPassages.all[0]

    /// First `correct` words correct, then one incorrect, one missed, one open, rest pending.
    static func match(words: [String], correct: Int, incorrect: Set<Int> = [], missed: Set<Int> = [],
                      assisted: Set<Int> = [], open: Int? = nil) -> MatchState {
        let ws: [WordMatch] = words.enumerated().map { i, w in
            let n = w.count
            if incorrect.contains(i) { return WordMatch(status: .incorrect, chars: Array(repeating: .incorrect, count: n)) }
            if missed.contains(i) { return WordMatch(status: .missed, chars: Array(repeating: .incorrect, count: n)) }
            if i == open {
                let half = n / 2
                return WordMatch(status: .open, chars: (0..<n).map { $0 < half ? .correct : .current })
            }
            if i < correct { return WordMatch(status: .correct, chars: Array(repeating: .correct, count: n), assisted: assisted.contains(i)) }
            return WordMatch(status: .pending, chars: Array(repeating: .pending, count: n))
        }
        return MatchState(words: ws, cursorWordIndex: open ?? correct, isComplete: false)
    }

    static var midRound: MatchState {
        match(words: passage.words, correct: 14, incorrect: [3], missed: [6], assisted: [9], open: 14)
    }

    static let result = TestResult(passage: passage, mode: .passage, duration: 42.7, wpm: 58.4, rawWPM: 63.1,
                                   accuracy: 0.93, correctWords: 26, totalWords: 28, wordsCorrected: 3,
                                   missedWords: 1, assistedWords: 2, passagesCompleted: 1,
                                   visionLeniencyEnabled: true)
}

#Preview("Passage start") {
    PassageDisplayView(words: PreviewData.passage.words, match: nil, source: PreviewData.passage.source)
        .padding(40).background(Theme.background)
}
#Preview("Passage mid-round") {
    PassageDisplayView(words: PreviewData.passage.words, match: PreviewData.midRound, source: PreviewData.passage.source)
        .padding(40).background(Theme.background)
}
#Preview("Stats") {
    LiveStatsBar(time: 42, wordsDone: 12, totalWords: 40, wpm: 38).padding(40).background(Theme.background)
}
#Preview("Stats timed") {
    LiveStatsBar(time: 18, countsDown: true, wordsDone: 57, wpm: 41).padding(40).background(Theme.background)
}
#Preview("Toolbar") {
    @Previewable @State var tool = RoundTool.pen
    @Previewable @State var s = SinglePlayerSettings()
    RoundToolbar(tool: $tool, canUndo: true, canRedo: false, onUndo: {}, onRedo: {}, onReset: {}, onNewPassage: {}) {
        RoundSettingsMenu(settings: $s, linesApplyNextTest: true)
    }
    .padding(60).background(Theme.background)
}
#Preview("Settings") {
    @Previewable @State var s = SinglePlayerSettings()
    RoundSettingsMenu(settings: $s, linesApplyNextTest: true).background(Theme.surface)
}
#Preview("Results") {
    ResultsCard(result: PreviewData.result, onRestart: {}, onNewPassage: {}).padding(40).background(Theme.background)
}
#endif
