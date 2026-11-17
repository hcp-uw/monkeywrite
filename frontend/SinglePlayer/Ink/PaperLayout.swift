import CoreGraphics

/// Ruled-paper geometry in canvas content coordinates (y grows downward).
///
/// Line `i` is the band `[topInset + i*lineHeight, topInset + (i+1)*lineHeight)`;
/// its rule (the line you write on) is at the bottom of the band. A layout is
/// fixed for a whole test: compute it once at test start or reset, from the
/// first laid-out height, and keep it even if the view resizes later.
struct PaperLayout: Equatable, Sendable {
    /// Blank paper above the first band.
    static let defaultTopInset: CGFloat = 12
    /// Blank lines always kept below the lowest written line, beyond one screen.
    static let extraBlankLines = 1

    var lineHeight: CGFloat
    var topInset: CGFloat

    init(lineHeight: CGFloat, topInset: CGFloat = PaperLayout.defaultTopInset) {
        self.lineHeight = max(1, lineHeight)
        self.topInset = max(0, topInset)
    }

    /// `visibleLines` bands filling a viewport `height` points tall.
    static func fitting(height: CGFloat, visibleLines: Int,
                        topInset: CGFloat = PaperLayout.defaultTopInset) -> PaperLayout {
        let lines = CGFloat(max(1, visibleLines))
        return PaperLayout(lineHeight: (height - topInset) / lines, topInset: topInset)
    }

    /// The y of the rule under line `index`.
    func ruleY(forLine index: Int) -> CGFloat {
        topInset + CGFloat(index + 1) * lineHeight
    }

    /// The vertical band of line `index`, top inclusive, bottom exclusive.
    func band(ofLine index: Int) -> Range<CGFloat> {
        (topInset + CGFloat(index) * lineHeight)..<ruleY(forLine: index)
    }

    /// The line whose band contains `y`, clamped to line 0 (the top inset and
    /// anything above it belong to line 0).
    func line(containing y: CGFloat) -> Int {
        let raw = ((y - topInset) / lineHeight).rounded(.down)
        guard raw.isFinite else { return 0 }
        return max(0, Int(raw))
    }

    /// How many lines the paper has: at least one screen plus two, and always
    /// `visibleLines + 1` blank lines below the lowest used line.
    static func lineCount(visibleLines: Int, highestUsedLine: Int?) -> Int {
        let minimum = visibleLines + 2
        guard let highestUsedLine else { return minimum }
        return max(minimum, highestUsedLine + visibleLines + extraBlankLines)
    }

    /// Content height of a paper with `lineCount` lines.
    func contentHeight(lineCount: Int) -> CGFloat {
        topInset + CGFloat(lineCount) * lineHeight
    }
}
