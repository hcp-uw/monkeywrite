import SwiftUI
import UIKit

/// Greedy line wrapping measured with the same UIFont used for rendering.
enum PassageLayout {
    /// Word index ranges, one per visual line. Each index in `breaks` starts
    /// a new paragraph: its line is preceded by an empty one (an empty range).
    static func lines(words: [String], maxWidth: CGFloat, breaks: [Int] = [],
                      font: UIFont = RoundFonts.passageUIFont) -> [Range<Int>] {
        guard !words.isEmpty else { return [] }
        let breaks = Set(breaks)
        let attrs = [NSAttributedString.Key.font: font]
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: attrs).width }
        let space = width(" ")
        var result: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (i, word) in words.enumerated() {
            let w = width(word)
            if i == start {
                used = w
            } else if breaks.contains(i) {
                result.append(start..<i)
                result.append(i..<i)
                start = i
                used = w
            } else if used + space + w <= maxWidth {
                used += space + w
            } else {
                result.append(start..<i)
                start = i
                used = w
            }
        }
        result.append(start..<words.count)
        return result
    }

    static func lineIndex(containing word: Int, in lines: [Range<Int>]) -> Int {
        lines.firstIndex { $0.contains(word) } ?? max(0, lines.count - 1)
    }
}

/// Shows exactly three visual lines: the line holding the cursor word is the
/// middle one, the lines above and below are faded to 35%. At the very start
/// the top row is blank (line 0 sits in the middle). Lines slide vertically
/// when the cursor moves to another line. Passages after the first (`breaks`,
/// their first word indices) follow after an empty line.
struct PassageDisplayView: View {
    let words: [String]
    var breaks: [Int] = []
    var match: MatchState?
    var source: String? = nil

    private var rowHeight: CGFloat { ceil(RoundFonts.passageUIFont.lineHeight * 1.5) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GeometryReader { geo in
                let lines = PassageLayout.lines(words: words, maxWidth: max(geo.size.width - 4, 50), breaks: breaks)
                let cursor = min(max(match?.cursorWordIndex ?? 0, 0), max(words.count - 1, 0))
                let current = PassageLayout.lineIndex(containing: cursor, in: lines)
                ZStack(alignment: .topLeading) {
                    ForEach(max(0, current - 2)...max(0, min(current + 2, lines.count - 1)), id: \.self) { i in
                        if i < lines.count {
                            lineText(lines[i])
                                .lineLimit(1)
                                .fixedSize()
                                .frame(width: geo.size.width, height: rowHeight, alignment: .leading)
                                .offset(y: CGFloat(i - current + 1) * rowHeight)
                                .opacity(i == current ? 1 : (abs(i - current) == 1 ? 0.35 : 0))
                        }
                    }
                }
                .frame(width: geo.size.width, height: rowHeight * 3, alignment: .topLeading)
                .clipped()
                .animation(.smooth(duration: 0.3), value: current)
            }
            .frame(height: rowHeight * 3)

            if let source {
                Text(source)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary.opacity(0.7))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(words.joined(separator: " "))
    }

    private func lineText(_ range: Range<Int>) -> Text {
        var out = AttributedString()
        for i in range {
            out += wordString(i)
            if i != range.upperBound - 1 {
                var sp = AttributedString(" ")
                sp.foregroundColor = RoundColors.pending
                out += sp
            }
        }
        return Text(out).font(RoundFonts.passage)
    }

    private func wordString(_ index: Int) -> AttributedString {
        let word = words[index]
        let wm = match.flatMap { index < $0.words.count ? $0.words[index] : nil }
        var out = AttributedString()
        for (ci, ch) in word.enumerated() {
            var run = AttributedString(String(ch))
            let state = wm.flatMap { ci < $0.chars.count ? $0.chars[ci] : nil } ?? .pending
            switch state {
            case .pending: run.foregroundColor = RoundColors.pending
            case .current: run.foregroundColor = RoundColors.current
            case .correct: run.foregroundColor = RoundColors.correct
            case .incorrect: run.foregroundColor = RoundColors.incorrect
            }
            if let wm {
                switch wm.status {
                case .open: run.underlineStyle = Text.LineStyle(pattern: .solid, color: RoundColors.caret)
                case .missed: run.underlineStyle = Text.LineStyle(pattern: .solid, color: RoundColors.incorrect)
                case .correct where wm.assisted:
                    run.underlineStyle = Text.LineStyle(pattern: .dot, color: RoundColors.correct.opacity(0.7))
                default: break
                }
            }
            out += run
        }
        return out
    }
}
