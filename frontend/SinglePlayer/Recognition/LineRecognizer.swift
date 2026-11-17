import PencilKit

/// Reads one paper line into a `WrittenLine`.
///
/// Heuristic:
/// 1. Recognize the whole line's strokes as one drawing (PKStrokeRecognizer is
///    most accurate with word context) and split its text on whitespace.
/// 2. Group the strokes into words by horizontal gaps (`WordGrouper`).
/// 3. Same number of words as groups: zip them (whole-line text, gap groups).
/// 4. Otherwise the gaps and the recognizer disagree (a wide letter gap, or two
///    words written close together). Recognize each group on its own:
///    - if the per-group words add up to the whole-line word count, keep the
///      whole-line text (more accurate) with the per-group stroke attribution;
///    - otherwise use the per-group words. A group read as several words
///      becomes several words that share the group's strokes; a group read as
///      nothing is dropped.
///    - if no group yields any text but the whole line did, keep the
///      whole-line words with empty `strokeIDs` (grouping unknown).
///
/// Cancellation-aware: throws `CancellationError` between awaits.
@MainActor
struct LineRecognizer {
    let recognizer: any StrokeRecognizing

    init(recognizer: any StrokeRecognizing) {
        self.recognizer = recognizer
    }

    /// `strokes` are the line's strokes in drawing order.
    func recognize(lineIndex: Int, strokes: [PKStroke], lineHeight: CGFloat) async throws -> WrittenLine {
        guard !strokes.isEmpty else { return WrittenLine(index: lineIndex, words: []) }
        try Task.checkCancellation()
        let session = await recognizer.prepare(PKDrawing(strokes: strokes))
        try Task.checkCancellation()
        let lineText = await session.wholeText() ?? ""
        try Task.checkCancellation()

        let lineWords = Self.words(in: lineText)
        let groups = WordGrouper.group(strokes, lineHeight: lineHeight)

        if !lineWords.isEmpty, lineWords.count == groups.count {
            return WrittenLine(index: lineIndex, words: zip(lineWords, groups).map {
                WrittenWord(text: $0, strokeIDs: $1)
            })
        }

        var groupWords: [WrittenWord] = []
        for group in groups {
            let text = await session.text(forStrokes: group) ?? ""
            try Task.checkCancellation()
            groupWords += Self.words(in: text).map { WrittenWord(text: $0, strokeIDs: group) }
        }
        return WrittenLine(index: lineIndex, words: Self.reconcile(lineWords: lineWords, groupWords: groupWords))
    }

    /// Step 4 of the heuristic, separated for testing.
    static func reconcile(lineWords: [String], groupWords: [WrittenWord]) -> [WrittenWord] {
        if !lineWords.isEmpty, lineWords.count == groupWords.count {
            return zip(lineWords, groupWords).map { WrittenWord(text: $0, strokeIDs: $1.strokeIDs) }
        }
        if groupWords.isEmpty {
            return lineWords.map { WrittenWord(text: $0, strokeIDs: []) }
        }
        return groupWords
    }

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
