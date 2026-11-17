import SwiftUI

/// One quiet line: "0:42   12/40   38 wpm", or in a timed test the time left
/// and the words so far: "0:18   57   41 wpm".
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
            Text(totalWords.map { "\(wordsDone)/\($0)" } ?? "\(wordsDone)")
            HStack(spacing: 6) {
                Text(wpm.map { String(Int($0.rounded())) } ?? "--")
                Text("wpm").foregroundStyle(Theme.secondary)
            }
        }
        .font(RoundFonts.stats)
        .foregroundStyle(Theme.accent)
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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
