import SwiftUI

/// One quiet line: "0:42   12/40 words   38 wpm", or in a timed test the time
/// left and the words so far: "0:18   57 words   41 wpm".
struct LiveStatsBar: View {
    /// Elapsed time, or the time left when `countsDown`.
    var time: TimeInterval
    var countsDown = false
    var wordsDone: Int
    /// Nil in a timed test, which has no fixed number of words.
    var totalWords: Int?
    var wpm: Double?

    var body: some View {
        HStack(spacing: 28) {
            Text(clock)
            unit(totalWords.map { "\(wordsDone)/\($0)" } ?? "\(wordsDone)", "words")
            unit(wpm.map { String(Int($0.rounded())) } ?? "--", "wpm")
        }
        .font(RoundFonts.stats)
        .foregroundStyle(Theme.accent)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func unit(_ value: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(value)
            Text(label).foregroundStyle(Theme.secondary)
        }
    }

    /// A countdown rounds up, so it shows 1:00 until a full second has passed
    /// and 0:00 only at the end.
    private var clock: String { Self.clock(countsDown ? time.rounded(.up) : time) }

    private var accessibilityText: String {
        let speed = wpm.map { "\(Int($0.rounded())) words per minute" } ?? "no speed yet"
        if let totalWords {
            return "Time \(clock), \(wordsDone) of \(totalWords) words, \(speed)"
        }
        return "\(clock) left, \(wordsDone) words, \(speed)"
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
