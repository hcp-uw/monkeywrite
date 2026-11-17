import Foundation

/// One step of a word-level alignment between written words and passage words.
/// Indices refer to the arrays given to the aligner.
enum AlignmentOp: Equatable, Sendable {
    /// Written word and passage word have equal keys.
    case match(written: Int, passage: Int)
    /// Written word stands for the passage word but is spelled differently.
    case substitute(written: Int, passage: Int)
    /// Two consecutive written words stand for one passage word ("to" "day" -> "today").
    /// Always an exact join, except that the second word may be the open word
    /// and only a prefix of the passage word so far.
    case merge(first: Int, second: Int, passage: Int)
    /// One written word stands for two consecutive passage words
    /// (`firstPassage` and `firstPassage + 1`): "ofthe" -> "of" "the".
    /// Always exact, except that an open word may cover only a prefix of the
    /// second passage word so far.
    case split(written: Int, firstPassage: Int)
    /// Passage word skipped although a later passage word was written.
    case skip(passage: Int)
    /// Written word with no passage word (ignored).
    case extra(written: Int)
}

/// Word-level edit-distance alignment of what was written against the passage.
///
/// Written content is aligned as a *prefix* of the passage: passage words
/// after the last aligned one are unwritten (no op, they are pending), so
/// they cost nothing. Written words past the end of the passage are extras.
///
/// Cost model:
/// - match: 0
/// - substitute: 0.5 + 0.5 * d / max(|w|, |p|), where d is the character
///   edit distance of the normalized keys. Range (0.5, 1.0]. Always cheaper
///   than skip + extra (1.9), and never more than an extra, so a misspelling
///   aligns to its intended word instead of becoming missed + extra (also at
///   the trailing edge, where an extra would otherwise compete with the free
///   end gap).
/// - skip passage word: 0.9 (slightly cheaper than a completely different
///   substitution, so "a c" against "a b c" reads as "b missed").
/// - extra written word: 1.0
/// - exact merge / split: 0.01; open-word prefix merge / split: 0.05.
/// Ties prefer, in order: skip, match/substitute, merge, split, extra; at the
/// end, the alignment that covers more passage words. Skips win ties because
/// the backtrace runs from the end: a tied skip is the later passage word,
/// so written words take the earliest passage words they can. With repeated
/// words ("and fresh, and" with "fresh, and" erased) the word written earlier
/// keeps its passage word, and an edit never makes words on earlier lines
/// look skipped.
enum PassageAligner {
    static let skipCost = 0.9
    static let extraCost = 1.0
    static let substituteBase = 0.5
    static let substituteScale = 0.5
    static let exactJoinCost = 0.01
    static let partialJoinCost = 0.05

    /// Aligns raw strings. Words normalizing to an empty key (stray
    /// punctuation) take no part and produce no op.
    static func align(written: [String], passage: [String]) -> [AlignmentOp] {
        let wIdx = written.indices.filter { !MatchKey.key(written[$0]).isEmpty }
        let pIdx = passage.indices.filter { !MatchKey.key(passage[$0]).isEmpty }
        let ops = alignKeys(written: wIdx.map { MatchKey.key(written[$0]) },
                            passage: pIdx.map { MatchKey.key(passage[$0]) })
        return ops.map { remap($0, written: wIdx, passage: pIdx) }
    }

    static func remap(_ op: AlignmentOp, written w: [Int], passage p: [Int]) -> AlignmentOp {
        switch op {
        case let .match(a, b): return .match(written: w[a], passage: p[b])
        case let .substitute(a, b): return .substitute(written: w[a], passage: p[b])
        case let .merge(a, b, c): return .merge(first: w[a], second: w[b], passage: p[c])
        case let .split(a, b): return .split(written: w[a], firstPassage: p[b])
        case let .skip(b): return .skip(passage: p[b])
        case let .extra(a): return .extra(written: w[a])
        }
    }

    private enum Step: UInt8 { case none = 0, diag, merge, split, skip, extra }

    /// Aligns non-empty keys. `openWritten` is the index of the open word (if
    /// any); only it may take part in a partial (prefix) merge or split.
    /// `substitutionCosts`, if given, is the precomputed n*m row-major matrix
    /// of `substituteCost(W[i], P[j])` (lets a caller cache rows between
    /// evaluations). Note: for `.split`, `firstPassage + 1` is the next index
    /// in `passage`.
    static func alignKeys(written W: [[MatchKeyCode]], passage P: [[MatchKeyCode]],
                          openWritten: Int? = nil, substitutionCosts: [Double]? = nil) -> [AlignmentOp] {
        let n = W.count, m = P.count
        guard n > 0 else { return [] }
        guard m > 0 else { return (0..<n).map { .extra(written: $0) } }
        let wt = KeyTable(W), pt = KeyTable(P)
        let sub: [Double]
        if let given = substitutionCosts, given.count == n * m { sub = given }
        else { sub = substitutionMatrix(written: wt, passage: pt) }
        let cols = m + 1
        var cost = [Double](repeating: 0, count: (n + 1) * cols)
        var back = [UInt8](repeating: 0, count: (n + 1) * cols)
        let eps = 1e-9
        let open = openWritten ?? -1

        cost.withUnsafeMutableBufferPointer { D in
        back.withUnsafeMutableBufferPointer { B in
        sub.withUnsafeBufferPointer { S in
        wt.codes.withUnsafeBufferPointer { wc in
        pt.codes.withUnsafeBufferPointer { pc in
        pt.start.withUnsafeBufferPointer { pStart in
        pt.length.withUnsafeBufferPointer { pLen in
            // Raw pointers: unchecked access keeps debug builds fast.
            let D = D.baseAddress!, B = B.baseAddress!, S = S.baseAddress!
            let pStart = pStart.baseAddress!, pLen = pLen.baseAddress!
            if m > 0 {
                for j in 1...m { D[j] = Double(j) * skipCost; B[j] = Step.skip.rawValue }
            }
            for i in 1...n {
                let row = i * cols, up = (i - 1) * cols
                D[row] = Double(i) * extraCost
                B[row] = Step.extra.rawValue
                guard m > 0 else { continue }
                let isOpen = open == i - 1
                let wS = wt.start[i - 1], wL = wt.length[i - 1]
                let w0S = i >= 2 ? wt.start[i - 2] : 0, w0L = i >= 2 ? wt.length[i - 2] : 0
                let subRow = (i - 1) * m
                for j in 1...m {
                    let pS = pStart[j - 1], pL = pLen[j - 1]
                    // 1. match / substitute
                    var best = D[up + j - 1] + S[subRow + j - 1]
                    var step = Step.diag
                    // 2. merge W[i-2] + W[i-1] -> P[j-1]
                    if i >= 2, w0L + wL <= pL,
                       equal(wc, w0S, pc, pS, w0L), equal(wc, wS, pc, pS + w0L, wL) {
                        let c = w0L + wL == pL ? exactJoinCost : (isOpen ? partialJoinCost : -1)
                        if c >= 0 {
                            let total = D[(i - 2) * cols + j - 1] + c
                            if total < best - eps { best = total; step = .merge }
                        }
                    }
                    // 3. split W[i-1] -> P[j-2] + P[j-1]
                    if j >= 2 {
                        let aS = pStart[j - 2], aL = pLen[j - 2]
                        let rest = wL - aL
                        if rest > 0, rest <= pL, equal(wc, wS, pc, aS, aL), equal(wc, wS + aL, pc, pS, rest) {
                            let c = rest == pL ? exactJoinCost : (isOpen ? partialJoinCost : -1)
                            if c >= 0 {
                                let total = D[up + j - 2] + c
                                if total < best - eps { best = total; step = .split }
                            }
                        }
                    }
                    // 4. skip passage word; wins ties (see the type comment)
                    let skip = D[row + j - 1] + skipCost
                    if skip < best + eps { best = min(best, skip); step = .skip }
                    // 5. extra written word
                    let extra = D[up + j] + extraCost
                    if extra < best - eps { best = extra; step = .extra }
                    D[row + j] = best
                    B[row + j] = step.rawValue
                }
            }
        }}}}}}}

        // Free end gap on the passage side: best end column in the last row,
        // preferring more coverage on ties.
        var j = 0
        var bestEnd = Double.infinity
        for c in 0...m {
            let v = cost[n * cols + c]
            if v <= bestEnd + eps { if v < bestEnd { bestEnd = v }; j = c }
        }

        var ops: [AlignmentOp] = []
        ops.reserveCapacity(n + j)
        var i = n
        while i > 0 || j > 0 {
            switch Step(rawValue: back[i * cols + j]) ?? .none {
            case .diag:
                ops.append(sub[(i - 1) * m + j - 1] == 0 ? .match(written: i - 1, passage: j - 1)
                                                        : .substitute(written: i - 1, passage: j - 1))
                i -= 1; j -= 1
            case .merge:
                ops.append(.merge(first: i - 2, second: i - 1, passage: j - 1))
                i -= 2; j -= 1
            case .split:
                ops.append(.split(written: i - 1, firstPassage: j - 2))
                i -= 1; j -= 2
            case .skip:
                ops.append(.skip(passage: j - 1)); j -= 1
            case .extra:
                ops.append(.extra(written: i - 1)); i -= 1
            case .none:
                i = 0; j = 0   // only (0, 0) has no step
            }
        }
        ops.reverse()
        return ops
    }

    @inline(__always)
    private static func equal(_ a: UnsafeBufferPointer<MatchKeyCode>, _ aS: Int,
                              _ b: UnsafeBufferPointer<MatchKeyCode>, _ bS: Int, _ len: Int) -> Bool {
        guard len > 0 else { return true }
        return memcmp(a.baseAddress! + aS, b.baseAddress! + bS, len &* MemoryLayout<MatchKeyCode>.stride) == 0
    }

    /// Keys stored contiguously.
    struct KeyTable {
        var codes: [MatchKeyCode] = []
        var start: [Int] = []
        var length: [Int] = []
        init(_ keys: [[MatchKeyCode]]) {
            start.reserveCapacity(keys.count); length.reserveCapacity(keys.count)
            for k in keys { start.append(codes.count); length.append(k.count); codes.append(contentsOf: k) }
        }
    }

    /// Row-major n*m matrix of substitution costs.
    static func substitutionMatrix(written wt: KeyTable, passage pt: KeyTable) -> [Double] {
        let n = wt.start.count, m = pt.start.count
        var out = [Double](repeating: 0, count: n * m)
        guard n > 0, m > 0 else { return out }
        let maxP = pt.length.max() ?? 0
        var scratch = [Int](repeating: 0, count: 2 * (maxP + 1))
        out.withUnsafeMutableBufferPointer { O in
        scratch.withUnsafeMutableBufferPointer { buf in
        wt.codes.withUnsafeBufferPointer { wc in
        pt.codes.withUnsafeBufferPointer { pc in
            for i in 0..<n {
                let a = UnsafeBufferPointer(rebasing: wc[wt.start[i] ..< wt.start[i] + wt.length[i]])
                for j in 0..<m {
                    let b = UnsafeBufferPointer(rebasing: pc[pt.start[j] ..< pt.start[j] + pt.length[j]])
                    O[i * m + j] = substituteCost(a, b, scratch: buf)
                }
            }
        }}}}
        return out
    }

    /// Substitution costs of one written key against every passage key.
    static func substitutionRow(written: [MatchKeyCode], passage pt: KeyTable) -> [Double] {
        substitutionMatrix(written: KeyTable([written]), passage: pt)
    }

    /// Substitution cost on raw buffers; `buf` must hold 2 * (b.count + 1) Ints.
    /// Written with raw pointers and wrapping arithmetic so debug builds stay fast.
    static func substituteCost(_ a: UnsafeBufferPointer<MatchKeyCode>, _ b: UnsafeBufferPointer<MatchKeyCode>,
                               scratch: UnsafeMutableBufferPointer<Int>) -> Double {
        let n = a.count, m = b.count
        guard n > 0, m > 0, let ap = a.baseAddress, let bp = b.baseAddress, let buf = scratch.baseAddress else {
            return n == m ? 0 : substituteBase + substituteScale
        }
        if n == m && memcmp(ap, bp, n &* MemoryLayout<MatchKeyCode>.stride) == 0 { return 0 }
        var prev = buf, cur = buf + (m &+ 1)
        var j = 0
        while j <= m { prev[j] = j; j &+= 1 }
        var i = 1
        while i <= n {
            cur[0] = i
            let ai = ap[i &- 1]
            j = 1
            while j <= m {
                var v = prev[j &- 1] &+ (ai == bp[j &- 1] ? 0 : 1)
                let del = prev[j] &+ 1
                if del < v { v = del }
                let ins = cur[j &- 1] &+ 1
                if ins < v { v = ins }
                cur[j] = v
                j &+= 1
            }
            swap(&prev, &cur)
            i &+= 1
        }
        return substituteBase + substituteScale * Double(prev[m]) / Double(max(n, m))
    }
}
