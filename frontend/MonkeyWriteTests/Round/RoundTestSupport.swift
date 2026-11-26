import PencilKit
import XCTest
@testable import MonkeyWrite

/// Reads each stroke as the text the test assigned to it; a line reads as its
/// strokes' texts left to right. Optionally holds every `prepare` on a gate
/// (arrival order) or delays it.
@MainActor
final class ScriptedStrokeRecognizer: StrokeRecognizing {
    var text: [UUID: String] = [:]
    /// When set, prepare call `n` waits for `gate.release(n, ())`.
    var gate: Gate<Void>?
    var delay: Duration = .zero
    private(set) var prepared: [[UUID]] = []
    var recognizerVersion = "scripted"

    func prepare(_ drawing: PKDrawing) async -> any StrokeRecognitionSession {
        prepared.append(drawing.strokes.map(\.id))
        if let gate { await gate.wait() }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return Session(strokes: drawing.strokes, text: text)
    }

    /// How many recognitions included any of `ids`.
    func preparedCount(containing ids: [UUID]) -> Int {
        prepared.filter { !Set($0).isDisjoint(with: ids) }.count
    }

    struct Session: StrokeRecognitionSession {
        let strokes: [PKStroke]
        let text: [UUID: String]

        func wholeText() async -> String? { read(strokes) }
        func text(forStroke id: UUID) async -> String? { text[id] }
        func text(forStrokes ids: [UUID]) async -> String? {
            let wanted = Set(ids)
            return read(strokes.filter { wanted.contains($0.id) })
        }

        private func read(_ strokes: [PKStroke]) -> String {
            strokes.sorted { $0.renderBounds.minX < $1.renderBounds.minX }
                .compactMap { text[$0.id] }.joined(separator: " ")
        }
    }
}

@MainActor
final class FakeTextImageRecognizer: TextImageRecognizing {
    var answer: [VisionRegion] = []
    private(set) var calls = 0
    private(set) var lastSettings: VisionSettings?

    func recognize(_ image: CGImage, settings: VisionSettings) async throws -> [VisionRegion] {
        calls += 1
        lastSettings = settings
        await Task.yield()
        return answer
    }
}

/// Stands in for the timed-mode clock: every `sleep(until:)` waits for
/// `fire()`.
@MainActor
final class ManualTimer {
    /// Every deadline slept for, in order.
    private(set) var deadlines: [Date] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func sleep(until deadline: Date) async {
        deadlines.append(deadline)
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Ends every sleep (cancelled timers then do nothing).
    func fire() {
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume() }
    }
}

struct FixedPassages: PassageSource {
    let passages: [Passage]
    func allPassages() -> [Passage] { passages }
    func nextPassage(excluding: [Passage.ID]) -> Passage {
        passages.first { !excluding.contains($0.id) }
            ?? passages.first { $0.id != excluding.last } ?? passages[0]
    }
}

extension XCTestCase {
    /// A UserDefaults suite of its own, removed when the test ends.
    func temporaryDefaults() -> UserDefaults {
        let suite = "MonkeyWriteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

/// A model on a 1000x600 paper (5 lines of ~117.6 pt) with scripted
/// recognizers, plus helpers that write one-stroke words.
@MainActor
final class RoundHarness {
    let recognizer = ScriptedStrokeRecognizer()
    let vision = FakeTextImageRecognizer()
    let timer = ManualTimer()
    let model: RoundModel
    var layout: PaperLayout { model.canvas.layout! }
    /// Touch-down of the next stroke written by `write`.
    var clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let strokeDuration: TimeInterval = 0.5

    static let passages = [
        Passage(id: "a", text: "the quick brown fox jumps over", source: "Test A"),
        Passage(id: "b", text: "a lazy dog", source: "Test B"),
    ]

    /// `mode` overrides the mode of `settings` (or of the loaded settings).
    init(passage: Passage = RoundHarness.passages[0], settings: SinglePlayerSettings? = nil,
         mode: TestMode = .passage, defaults: UserDefaults? = nil) {
        let timer = timer
        model = RoundModel(strokeRecognizer: recognizer, textRecognizer: vision,
                           passageSource: FixedPassages(passages: Self.passages),
                           passage: passage, defaults: defaults,
                           sleep: { await timer.sleep(until: $0) })
        var applied = settings ?? model.settings
        applied.mode = mode
        model.settings = applied
        model.paperSizeChanged(CGSize(width: 1000, height: 600))
    }

    /// A zig-zag word stroke at word `slot` of paper `line`.
    func stroke(line: Int, slot: Int, start: Date? = nil, wide: Bool = false) -> PKStroke {
        let band = layout.band(ofLine: line)
        let lh = layout.lineHeight
        let x0 = 40 + CGFloat(slot) * 160
        let width: CGFloat = wide ? 90 : 70
        let top = band.lowerBound + 0.3 * lh, bottom = band.lowerBound + 0.8 * lh
        let count = 8
        let begin = start ?? clock
        let points = (0..<count).map { i -> PKStrokePoint in
            let t = CGFloat(i) / CGFloat(count - 1)
            let y = i.isMultiple(of: 2) ? bottom : top
            return PKStrokePoint(location: CGPoint(x: x0 + t * width, y: y),
                                 timeOffset: Double(t) * strokeDuration,
                                 size: CGSize(width: 4, height: 4), opacity: 1, force: 1,
                                 azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .white),
                        path: PKStrokePath(controlPoints: points, creationDate: begin))
    }

    /// Writes one-stroke words, each one second after the previous, and
    /// returns their strokes.
    @discardableResult
    func write(_ words: [(line: Int, slot: Int, text: String)]) -> [PKStroke] {
        var added: [PKStroke] = []
        for word in words {
            let s = stroke(line: word.line, slot: word.slot)
            clock = clock.addingTimeInterval(1)
            recognizer.text[s.id] = word.text
            added.append(s)
        }
        model.canvas.drawingChanged(model.canvas.drawing.appending(PKDrawing(strokes: added)))
        return added
    }

    @discardableResult
    func write(line: Int, slot: Int, _ text: String) -> PKStroke {
        write([(line, slot, text)])[0]
    }

    func erase(_ strokes: [PKStroke]) {
        let ids = Set(strokes.map(\.id))
        var drawing = model.canvas.drawing
        drawing.strokes.removeAll { ids.contains($0.id) }
        model.canvas.drawingChanged(drawing)
    }

    func statuses() -> [WordStatus] { model.match.words.map(\.status) }
}
