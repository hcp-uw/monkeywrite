import Foundation

/// Normalized comparison keys for words.
///
/// Leniency rules: capitalization never matters and punctuation is fully
/// optional, so a key is the word's letters and digits, lowercased, with
/// everything else (apostrophes, curly quotes, dashes, commas...) removed.
/// "Don't" and "dont" have the same key. Accents are kept ("é" != "e").
///
/// A key is an array of integer codes (one per letter) so comparisons and
/// edit distances are cheap.
typealias MatchKeyCode = UInt32

enum MatchKey {
    /// The normalized key of `text`. Empty when it has no letters or digits.
    static func key(_ text: String) -> [MatchKeyCode] {
        var out: [MatchKeyCode] = []
        out.reserveCapacity(text.utf8.count)
        for ch in text {
            if let code = code(for: ch) { out.append(code) }
        }
        return out
    }

    /// The normalized key as a String (handy for tests and debugging).
    static func normalized(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber }).lowercased()
    }

    /// The code of one character, or nil for punctuation/whitespace/symbols.
    @inline(__always)
    static func code(for ch: Character) -> MatchKeyCode? {
        if let ascii = ch.asciiValue {
            switch ascii {
            case 0x30...0x39, 0x61...0x7A: return MatchKeyCode(ascii)       // 0-9 a-z
            case 0x41...0x5A: return MatchKeyCode(ascii + 0x20)               // A-Z
            default: return nil
            }
        }
        guard ch.isLetter || ch.isNumber else { return nil }
        let lower = String(ch).precomposedStringWithCanonicalMapping.lowercased()
        let scalars = lower.unicodeScalars
        if scalars.count == 1, let s = scalars.first { return s.value }
        // Rare multi-scalar letter: a process-stable hash outside the Unicode range.
        var hasher = Hasher()
        hasher.combine(lower)
        return MatchKeyCode(truncatingIfNeeded: hasher.finalize()) | 0x8000_0000
    }
}
