import PencilKit

/// A stroke reduced to the geometry the line and word logic needs: its spine
/// (sampled path locations in canvas coordinates, ink width not included).
struct StrokeGeometry: Equatable, Sendable {
    let id: UUID
    let points: [CGPoint]
    /// Bounds of `points` (zero-size for a single point).
    let bounds: CGRect

    init(id: UUID, points: [CGPoint]) {
        self.id = id
        self.points = points
        if let first = points.first {
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points.dropFirst() {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        } else {
            bounds = .null
        }
    }

    /// Samples `stroke.path` every couple of points and applies
    /// `stroke.transform` (path locations are in stroke space).
    init(_ stroke: PKStroke) {
        let transform = stroke.transform
        var points = stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(transform) }
        if points.isEmpty {
            points = stroke.path.map { $0.location.applying(transform) }
        }
        self.init(id: stroke.id, points: points)
    }
}

/// Decides which paper line each stroke belongs to. Pure: no PencilKit state,
/// so it is safe to call on every edit and easy to test.
///
/// One stroke's shape alone often cannot tell an ascender or capital of line
/// N+1 rising into line N's band from a descender of line N hanging into
/// line N+1's band. So, in order:
/// 1. A letter stroke whose extent fits only one line (see `candidateLines`)
///    is *settled* there.
/// 2. Any other letter stroke follows its word: the settled strokes reached
///    by walking from it through the strokes drawn just before and just after
///    it, while they stay close horizontally and share the word's height.
/// 3. With no word (or a word pulling both ways), it avoids a line whose
///    settled ink already fills its x-range (ink is not written over ink),
///    then falls back to its own shape (`primaryLine`).
/// 4. Marks (dots, crossbars) join the stroke drawn just before them when it
///    is close, else the nearest earlier letter, never one whose line's rule
///    is above them.
/// A stroke's line therefore only depends on strokes drawn around it in time
/// and, for marks, on strokes drawn before them: writing a new word changes
/// nothing on other lines except strokes that are genuinely ambiguous.
enum LineAssigner {
    /// The stroke's "upper body" is this far down its vertical extent. Using it
    /// instead of the center keeps descenders (g, y, p, j, q) that dip deep
    /// into the line below on their own line, while ascenders reaching into
    /// the line above are still below the rule they rise over. Only decides
    /// strokes that neither their geometry nor their word settles.
    static let upperBodyFraction: CGFloat = 0.3
    /// Strokes smaller than this (times the line height) in both directions
    /// are marks: i/j dots, short crossbars, periods, apostrophes.
    static let tinyFraction: CGFloat = 0.35
    /// A mark joins a letter stroke within this horizontal gap
    /// (times the line height).
    static let neighborGapFraction: CGFloat = 0.5
    /// ... whose bounds are also within this distance (times the line height),
    /// so a stray mark far above or below text keeps its own line.
    static let neighborDistanceFraction: CGFloat = 1.0

    // MARK: Plausible lines (times the line height)

    /// A letter of a line reaches at most this far above the line's band
    /// (large handwriting's ascenders and capitals).
    static let maxAscentFraction: CGFloat = 0.9
    /// ... at most this far below the line's rule (deep descenders).
    static let maxDescentFraction: CGFloat = 0.95
    /// ... and, when it continues below the rule, starts at least this far
    /// above it (a descender starts in the x-height).
    static let minRiseFraction: CGFloat = 0.15
    /// A stroke entering a line's band from above (an ascender or capital of
    /// that line) reaches at least this far down the band: its baseline is
    /// near the rule, like its word's.
    static let baselineFraction: CGFloat = 0.65
    /// A stroke ending above this far into its lowest band floats in the band's
    /// upper part (a T-bar, the top of a capital or an f): it may also be the
    /// top of a tall letter of the next line.
    static let floatFraction: CGFloat = 0.4

    // MARK: Word context

    /// Consecutive strokes of a word are at most this far apart horizontally
    /// (a letter gap, or a word gap on the same line)...
    static let contextGapFraction: CGFloat = 1.0
    /// ... and overlap vertically by at least this fraction of the shorter
    /// one (letters of a word share its x-height), with a little slack.
    static let contextOverlapFraction: CGFloat = 0.5
    static let contextSlackFraction: CGFloat = 0.1
    /// How many ambiguous strokes a walk crosses to reach a settled one.
    static let contextSteps = 6
    /// A line's settled ink covering more than this fraction of a stroke's
    /// x-range means the stroke would be written over it.
    static let collisionFraction: CGFloat = 0.5

    // MARK: Marks

    /// A mark is at most this far below the rule of its letter's line
    /// (periods and commas sit on it; dots and crossbars are above it)...
    static let markBelowRuleFraction: CGFloat = 0.1
    /// ... and at most this far above that line's band (dots of tall letters).
    static let markAboveBandFraction: CGFloat = 0.6

    /// The line of every stroke, keyed by stroke ID.
    static func assign(_ strokes: [PKStroke], layout: PaperLayout) -> [UUID: Int] {
        assign(strokes.map(StrokeGeometry.init), layout: layout)
    }

    static func assign(_ strokes: [StrokeGeometry], layout: PaperLayout) -> [UUID: Int] {
        let lh = layout.lineHeight
        var letters: [Letter] = []
        // Each mark with the number of letters drawn before it.
        var marks: [(lettersBefore: Int, geometry: StrokeGeometry)] = []
        for stroke in strokes where !stroke.points.isEmpty {
            if isTiny(stroke, lineHeight: lh) {
                marks.append((letters.count, stroke))
            } else {
                letters.append(Letter(geometry: stroke, candidates: candidateLines(of: stroke, layout: layout),
                                      primary: primaryLine(of: stroke, layout: layout)))
            }
        }

        // Settled ink per line, for collisions.
        var settledByLine: [Int: [CGRect]] = [:]
        for letter in letters where letter.isSettled {
            settledByLine[letter.candidates[0], default: []].append(letter.geometry.bounds)
        }

        var letterLines: [Int] = []
        letterLines.reserveCapacity(letters.count)
        for index in letters.indices {
            let letter = letters[index]
            if letter.isSettled {
                letterLines.append(letter.candidates[0])
                continue
            }
            guard !letter.candidates.isEmpty else {
                letterLines.append(letter.primary)
                continue
            }
            let back = wordVote(from: index, step: -1, letters: letters, lineHeight: lh)
            let forward = wordVote(from: index, step: 1, letters: letters, lineHeight: lh)
            let votes = [back, forward].compactMap { $0 }
            if let first = votes.first, votes.allSatisfy({ $0 == first }) {
                letterLines.append(first)
                continue
            }
            // No word, or a word pulling both ways.
            let pool = votes.isEmpty ? letter.candidates : votes
            let free = pool.filter {
                !collides(letter.geometry.bounds, with: settledByLine[$0] ?? [])
            }
            letterLines.append(free.count == 1 ? free[0] : closest(to: letter.primary, in: pool))
        }

        var result: [UUID: Int] = [:]
        for (letter, line) in zip(letters, letterLines) {
            result[letter.geometry.id] = line
        }
        for (lettersBefore, mark) in marks {
            result[mark.id] = markLine(mark, lettersBefore: lettersBefore, letters: letters,
                                       lines: letterLines, layout: layout)
        }
        return result
    }

    /// Strokes grouped by line, each line's strokes in drawing order.
    static func strokesByLine(_ strokes: [PKStroke], layout: PaperLayout) -> [Int: [PKStroke]] {
        let lines = assign(strokes, layout: layout)
        var result: [Int: [PKStroke]] = [:]
        for stroke in strokes {
            guard let line = lines[stroke.id] else { continue }
            result[line, default: []].append(stroke)
        }
        return result
    }

    /// The line whose band contains the stroke's upper-body point, clamped to 0.
    static func primaryLine(of stroke: StrokeGeometry, layout: PaperLayout) -> Int {
        let y = stroke.bounds.minY + upperBodyFraction * stroke.bounds.height
        return layout.line(containing: y)
    }

    /// The lines the stroke could be a letter of, ascending: the bands it
    /// touches (plus the next line when it floats high in its lowest band),
    /// keeping those it neither rises too far above, nor hangs too far below,
    /// nor only grazes from below, nor enters from above without reaching
    /// down to the baseline. Empty for strokes no line can hold (a
    /// scribble across several lines).
    static func candidateLines(of stroke: StrokeGeometry, layout: PaperLayout) -> [Int] {
        let lh = layout.lineHeight
        let b = stroke.bounds
        let lo = layout.line(containing: b.minY)
        let hi = layout.line(containing: b.maxY)
        let floats = b.maxY < layout.band(ofLine: hi).lowerBound + floatFraction * lh
        return (lo...(floats ? hi + 1 : hi)).filter { line in
            let top = layout.band(ofLine: line).lowerBound
            let rule = layout.ruleY(forLine: line)
            if line > 0 && b.minY < top - maxAscentFraction * lh { return false }
            if b.maxY > rule + maxDescentFraction * lh { return false }
            if line < hi && b.minY > rule - minRiseFraction * lh { return false }
            if line > lo && line <= hi && b.maxY < top + baselineFraction * lh { return false }
            return true
        }
    }

    static func isTiny(_ stroke: StrokeGeometry, lineHeight: CGFloat) -> Bool {
        max(stroke.bounds.width, stroke.bounds.height) < tinyFraction * lineHeight
    }

    /// 0 when the x ranges overlap.
    static func horizontalGap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, max(a.minX - b.maxX, b.minX - a.maxX))
    }

    // MARK: Private

    private struct Letter {
        let geometry: StrokeGeometry
        let candidates: [Int]
        let primary: Int
        var isSettled: Bool { candidates.count == 1 }
    }

    /// The line of the first settled stroke reached from `index` by walking
    /// through consecutive strokes of the same word in drawing order, if it is
    /// one of the lines every ambiguous stroke on the way could be on.
    private static func wordVote(from index: Int, step: Int, letters: [Letter], lineHeight: CGFloat) -> Int? {
        var allowed = letters[index].candidates
        var current = index
        for _ in 0..<contextSteps {
            let next = current + step
            guard letters.indices.contains(next),
                  sameWord(letters[current].geometry.bounds, letters[next].geometry.bounds, lineHeight: lineHeight)
            else { return nil }
            let neighbor = letters[next]
            if neighbor.isSettled {
                return allowed.contains(neighbor.candidates[0]) ? neighbor.candidates[0] : nil
            }
            allowed = allowed.filter(neighbor.candidates.contains)
            if allowed.isEmpty { return nil }
            current = next
        }
        return nil
    }

    private static func sameWord(_ a: CGRect, _ b: CGRect, lineHeight: CGFloat) -> Bool {
        guard horizontalGap(a, b) <= contextGapFraction * lineHeight else { return false }
        let slack = contextSlackFraction * lineHeight
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY) + slack
        let shorter = max(min(a.height, b.height), slack)
        return overlap >= contextOverlapFraction * shorter
    }

    /// Whether `ink` covers more than `collisionFraction` of `bounds`' x-range.
    private static func collides(_ bounds: CGRect, with ink: [CGRect]) -> Bool {
        let ranges = ink.compactMap { rect -> (CGFloat, CGFloat)? in
            let lower = max(rect.minX, bounds.minX), upper = min(rect.maxX, bounds.maxX)
            return lower <= upper ? (lower, upper) : nil
        }.sorted { $0.0 < $1.0 }
        guard !ranges.isEmpty else { return false }
        guard bounds.width > 0 else { return true }
        var covered: CGFloat = 0
        var run = ranges[0]
        for range in ranges.dropFirst() {
            if range.0 <= run.1 {
                run.1 = max(run.1, range.1)
            } else {
                covered += run.1 - run.0
                run = range
            }
        }
        covered += run.1 - run.0
        return covered > collisionFraction * bounds.width
    }

    /// `line` if it is in `pool`, else the nearest line of `pool` (the upper on a tie).
    private static func closest(to line: Int, in pool: [Int]) -> Int {
        pool.min { (abs($0 - line), $0) < (abs($1 - line), $1) } ?? line
    }

    private static func markLine(_ mark: StrokeGeometry, lettersBefore: Int, letters: [Letter],
                                 lines: [Int], layout: PaperLayout) -> Int {
        let lh = layout.lineHeight
        let center = CGPoint(x: mark.bounds.midX, y: mark.bounds.midY)
        func distanceIfEligible(_ index: Int) -> CGFloat? {
            let bounds = letters[index].geometry.bounds
            let line = lines[index]
            guard horizontalGap(mark.bounds, bounds) <= neighborGapFraction * lh,
                  center.y <= layout.ruleY(forLine: line) + markBelowRuleFraction * lh,
                  center.y >= layout.band(ofLine: line).lowerBound - markAboveBandFraction * lh
            else { return nil }
            let d = distance(from: center, to: bounds)
            return d <= neighborDistanceFraction * lh ? d : nil
        }
        // The letter drawn just before: the i stem before its dot, the t before its bar.
        if lettersBefore > 0, distanceIfEligible(lettersBefore - 1) != nil {
            return lines[lettersBefore - 1]
        }
        // Else the nearest earlier letter, the latest on a tie.
        var best: (distance: CGFloat, line: Int)?
        for index in stride(from: lettersBefore - 1, through: 0, by: -1) {
            guard let d = distanceIfEligible(index) else { continue }
            if best == nil || d < best!.distance { best = (d, lines[index]) }
        }
        return best?.line ?? primaryLine(of: mark, layout: layout)
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
