import Combine
import PencilKit
import SwiftUI

/// One single-player test: the paper, the passage, recognition and matching.
///
/// Recognition is per paper line. Every canvas change groups the strokes by
/// line; only lines whose strokes changed (see `LineSignature`) are
/// recognized again, each by its own `.coalesceNewest` pipeline (at most one
/// job running and one waiting per line, newest wins, older results never
/// replace newer ones). A line whose strokes come back unchanged (undo, redo)
/// reuses its earlier result from `recognitionCache` instead of running the
/// recognizer, and barriers its pipeline so in-flight work for the
/// in-between strokes cannot publish over it. Every result, line removal or
/// edit builds a `WritingSnapshot` from the cached lines (stale ones too, so
/// words do not vanish while their line is re-read) and evaluates it.
///
/// Timing:
/// - Start: touch-down of the earliest stroke drawn in this test (the earliest
///   `creationDate` ever seen, so erasing or undoing the first stroke does
///   not move it). Cleared by Reset, New passage and Restart; restored when a
///   reset is undone.
/// - End: the end of the latest stroke in the drawing revisions the shown
///   recognition results were based on (each line job captures the latest
///   stroke end of the whole drawing when it is submitted). So recognition
///   latency never counts: the clock stops when the pen lifted, not when the
///   analyzer finished.
///
/// Reset is undoable: the test state at the reset is saved, the paper is
/// emptied, and undoing the reset (before any new stroke) restores both the
/// ink and the saved state. The first stroke or erase on the reset paper
/// discards the saved state.
///
/// Timed mode: when the last word of the text is correct, another passage
/// is appended to it (`passages`) and the writer just keeps writing on the
/// same paper; once appended, a passage stays for the rest of the test. A
/// timer armed at the start ends the test at start + limit: the paper
/// freezes at once, lines written before then finish recognition, and
/// everything written is scored as locked.
@MainActor
final class RoundModel: ObservableObject {
    // MARK: Published state

    let canvas: InkCanvasModel
    /// The text being written: one passage, or a timed test's passages so far.
    @Published private(set) var passages: [Passage]
    @Published private(set) var match: MatchState
    /// Set once the test is finished; the paper is frozen while it is.
    @Published private(set) var result: TestResult?
    /// Touch-down of the earliest stroke of this test.
    @Published private(set) var startDate: Date?
    /// The paper lines of the running test (settings apply on the next test).
    @Published private(set) var activeTestVisibleLines: Int
    @Published var settings: SinglePlayerSettings {
        didSet { settingsChanged(from: oldValue) }
    }
    /// The running test's mode: `settings.mode` when it started (changing
    /// the setting starts a new test).
    @Published private(set) var mode: TestMode

    /// The passage the test started with (what Restart goes back to).
    var passage: Passage { passages[0] }
    /// The words of every passage, in order.
    var words: [String] { session.prepared.words }
    /// Where each passage after the first starts in `words`.
    var passageStarts: [Int] { Array(session.passageEnds.dropLast()) }
    /// The passage holding the cursor word.
    var cursorPassage: Passage { passages[min(session.passageIndex(containing: match.cursorWordIndex), passages.count - 1)] }

    var linesApplyNextTest: Bool { settings.visibleLines != activeTestVisibleLines }
    var isFinished: Bool { result != nil }
    /// First-attempt history of the running test (see `MatchSession`).
    var firstAttempt: [Bool?] { session.firstAttempt }
    /// The newest recognized text of every line with strokes.
    var recognizedLines: [Int: WrittenLine] { entries.compactMapValues { $0.result?.line } }
    /// Lines whose recognition is missing or older than their strokes.
    var pendingLines: Set<Int> { Set(entries.filter { !$0.value.isCurrent }.keys) }

    // MARK: Dependencies

    private let strokeRecognizer: any StrokeRecognizing
    private let textRecognizer: any TextImageRecognizing
    private let passageSource: any PassageSource
    private let defaults: UserDefaults?
    private let now: () -> Date
    /// Suspends until a wall-clock date (cancellable); drives the timed-mode
    /// end so tests can control it.
    private let sleep: @MainActor (Date) async -> Void

    // MARK: Test state

    private var session: MatchSession
    private var timerTask: Task<Void, Never>?
    private var timerDeadline: Date?
    /// Timed mode: the time is up and the end waits for line recognition.
    private var timeIsUp = false

    private struct CachedLine {
        var line: WrittenLine
        /// The strokes the result was computed for.
        var signature: LineSignature
        /// Latest stroke end of the drawing the recognition was based on.
        var basisEnd: Date?
    }

    private struct LineEntry {
        /// The line's strokes now.
        var signature: LineSignature
        /// The newest result shown for the line, possibly for older strokes.
        var result: CachedLine?
        var isCurrent: Bool { result?.signature == signature }
    }

    private struct LineJob {
        var lineIndex: Int
        var strokes: [PKStroke]
        var signature: LineSignature
        var lineHeight: CGFloat
        var basisEnd: Date?
    }

    private struct LineKey: Hashable {
        var line: Int
        var signature: LineSignature
    }

    /// The test state an undoable reset can bring back.
    private struct SavedTest {
        var session: MatchSession
        var startDate: Date?
        var results: [Int: CachedLine]
        var match: MatchState
    }

    private var entries: [Int: LineEntry] = [:]
    private var pipelines: [Int: AnalysisPipeline<LineJob, WrittenLine>] = [:]
    /// Revision counter shared by all line pipelines (monotonic per line).
    private var generation = 0
    private var recognitionCache: [LineKey: WrittenLine] = [:]
    private static let recognitionCacheLimit = 512

    private var savedReset: SavedTest?
    private var wasShowingReset = false

    // MARK: Vision leniency state

    /// Vision candidates per word, keyed by the word's stroke IDs. An empty
    /// array means Vision ran and found nothing.
    private var visionAlternatives: [Set<UUID>: [String]] = [:]
    private var visionQueue: [[UUID]] = []
    private var visionRunning: Set<UUID>?
    private var visionTask: Task<Void, Never>?
    private var visionToken = 0
    /// Vision jobs started (for tests and metrics).
    private(set) var visionRequestCount = 0

    // MARK: Init

    init(
        strokeRecognizer: any StrokeRecognizing = PencilKitStrokeRecognizer(),
        textRecognizer: any TextImageRecognizing = VisionTextRecognizer(),
        passageSource: any PassageSource = BundledPassages(),
        passage: Passage? = nil,
        defaults: UserDefaults? = .standard,
        now: @escaping () -> Date = Date.init,
        sleep: (@MainActor (Date) async -> Void)? = nil
    ) {
        self.strokeRecognizer = strokeRecognizer
        self.textRecognizer = textRecognizer
        self.passageSource = passageSource
        self.defaults = defaults
        self.now = now
        self.sleep = sleep ?? { deadline in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(now()))))
        }
        let settings = defaults.map(SettingsStorage.load) ?? SinglePlayerSettings()
        self.settings = settings
        self.mode = settings.mode
        let passage = passage ?? passageSource.randomPassage(excluding: nil)
        self.passages = [passage]
        var session = MatchSession(passage: passage)
        self.match = session.evaluate(WritingSnapshot(lines: [], activeLineIndex: nil), settings: settings)
        self.session = session
        self.canvas = InkCanvasModel(visibleLines: settings.visibleLines, fingerWriting: settings.fingerWriting)
        canvas.autoSwitchToPen = settings.autoSwitchToPen
        self.activeTestVisibleLines = canvas.visibleLines
        canvas.onChange = { [weak self] change in self?.canvasChanged(change) }
    }

    // MARK: Commands

    /// No-ops once time is up: the paper is frozen while the end is scored.
    func undo() { if !timeIsUp { canvas.undo() } }
    func redo() { if !timeIsUp { canvas.redo() } }

    /// Empties the paper and starts the test over, undoably (see the type
    /// comment). A pending change of the line count makes it a fresh test
    /// instead (not undoable), because the strokes of an undone reset must
    /// come back on the lines they were written on. So does a reset once
    /// time is up.
    func reset() {
        if linesApplyNextTest || timeIsUp {
            startTest(with: passage)
        } else if !canvas.resetUndoably() {
            // The paper was already empty: nothing to undo back to.
            savedReset = nil
            clearTestState()
        }
    }

    /// A different passage on fresh paper.
    func newPassage() {
        startTest(with: passageSource.randomPassage(excluding: passage.id))
    }

    /// The passage the test started with, on fresh paper.
    func restart() {
        startTest(with: passage)
    }

    /// The paper view's size. While the paper is pristine (no strokes, no
    /// history) a new size re-fits the lines, so rotating to landscape
    /// right after opening the round does not keep portrait-sized lines.
    func paperSizeChanged(_ size: CGSize) {
        guard size.height > 0 else { return }
        canvas.viewportDidChange(size)
        guard canvas.drawing.strokes.isEmpty, !canvas.canUndo, let layout = canvas.layout else { return }
        let fitted = PaperLayout.fitting(height: size.height, visibleLines: canvas.visibleLines)
        guard abs(fitted.lineHeight - layout.lineHeight) > 0.5 else { return }
        let tool = canvas.tool
        canvas.startNewTest(visibleLines: canvas.visibleLines)
        canvas.tool = tool
    }

    // MARK: Live stats

    /// Timed mode's limit; nil in passage mode.
    var timeLimit: TimeInterval? {
        if case let .timed(seconds) = mode { TimeInterval(seconds) } else { nil }
    }

    /// Timed mode: when the time is up; nil before the first stroke.
    var deadline: Date? {
        guard let timeLimit, let startDate else { return nil }
        return startDate.addingTimeInterval(timeLimit)
    }

    /// Time since the first stroke (at most the time limit); the final
    /// duration once finished.
    func elapsed(at date: Date) -> TimeInterval {
        if let result { return result.duration }
        guard let startDate else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(startDate))
        return timeLimit.map { min(elapsed, $0) } ?? elapsed
    }

    var elapsedNow: TimeInterval { elapsed(at: now()) }

    /// Words before the cursor (all words counted in the result once
    /// finished).
    var wordsDone: Int {
        result?.totalWords ?? match.cursorWordIndex
    }

    /// Live WPM at `elapsed`, nil until a word has locked.
    func liveWPM(elapsed: TimeInterval) -> Double? {
        if let result { return result.wpm }
        guard elapsed >= 1, match.words.contains(where: { $0.status == .correct || $0.status == .incorrect }) else { return nil }
        return session.tally(reachedOnly: true).wpm(duration: elapsed)
    }

    /// For the debug overlay: the open word's raw text, the paper line of the
    /// latest stroke, that line's raw text, and how many lines are being read.
    var debugSummary: String {
        let snapshot = currentSnapshot()
        let line = snapshot.activeLineIndex
        let words = snapshot.lines.first { $0.index == line }?.words ?? []
        let open = words.last { word in snapshot.activeStrokeID.map(word.strokeIDs.contains) == true } ?? words.last
        let lineText = words.isEmpty ? "—" : words.map(\.text).joined(separator: " ")
        return "open \(open?.text ?? "—")   line \(line.map(String.init) ?? "—"): \(lineText)   pending \(pendingLines.count)"
    }

    // MARK: Tests

    /// Waits until no line recognition or Vision job is running or queued.
    func waitForAnalysis() async {
        while true {
            await waitForLineRecognition()
            guard let visionTask else { return }
            await visionTask.value
        }
    }

    /// Waits until the timed-mode timer (and the end it triggers) is done.
    func waitForTimer() async {
        await timerTask?.value
    }

    private func waitForLineRecognition() async {
        while true {
            for pipeline in Array(pipelines.values) { await pipeline.waitUntilSettled() }
            if pipelines.values.allSatisfy({ !$0.state.isUpdating }) { return }
            await Task.yield()
        }
    }

    // MARK: Canvas changes

    private func canvasChanged(_ change: InkCanvasModel.Change) {
        defer { wasShowingReset = canvas.document.isShowingUndoableReset }
        switch change {
        case .newTest:
            savedReset = nil
            clearTestState()
        case .reset:
            savedReset = result == nil ? captureTest() : nil
            clearTestState()
        case .edit, .undo, .redo, .clear:
            guard result == nil else { return }
            let document = canvas.document
            // An edit made the reset final (or forgot it): nothing to restore.
            if document.resetDepth == nil { savedReset = nil }
            if document.isShowingUndoableReset {
                clearTestState()   // redo back onto the reset paper
            } else if wasShowingReset, let saved = savedReset {
                restore(saved)     // the reset was undone
            }
            analyzeDrawing()
        }
    }

    private func startTest(with passage: Passage) {
        passages = [passage]
        session = MatchSession(passage: passage)
        // Calls back with `.newTest`, which clears the test state.
        canvas.startNewTest(visibleLines: settings.visibleLines)
    }

    /// Back to an empty test on the first passage, in the mode of the
    /// settings (the paper is handled by the caller).
    private func clearTestState() {
        cancelTimer()
        for pipeline in pipelines.values { pipeline.barrier(showing: .idle) }
        pipelines = [:]
        entries = [:]
        cancelVision()
        if canvas.document.isEmpty && !canvas.canUndo { recognitionCache = [:] }
        session.reset()
        if passages.count > 1 { passages = session.passages }
        startDate = nil
        result = nil
        timeIsUp = false
        if mode != settings.mode { mode = settings.mode }
        canvas.isWritingEnabled = true
        activeTestVisibleLines = canvas.visibleLines
        match = session.evaluate(WritingSnapshot(lines: [], activeLineIndex: nil), settings: settings)
    }

    /// Timed mode: the text is complete, so another passage follows it
    /// (one not used in this test yet, when there is one).
    private func appendNextPassage() {
        let used = Set(passages.map(\.id))
        let next = passageSource.allPassages().filter { !used.contains($0.id) }.randomElement()
            ?? passageSource.randomPassage(excluding: passages.last?.id)
        session.append(next)
        passages = session.passages
    }

    private func captureTest() -> SavedTest {
        SavedTest(session: session, startDate: startDate,
                  results: entries.compactMapValues(\.result), match: match)
    }

    private func restore(_ saved: SavedTest) {
        clearTestState()
        session = saved.session
        passages = session.passages
        startDate = saved.startDate
        // Each line starts at the strokes its result is for; `analyzeDrawing`
        // then re-reads only lines whose strokes differ.
        entries = saved.results.mapValues { LineEntry(signature: $0.signature, result: $0) }
        match = saved.match
    }

    /// Groups the strokes by line, re-recognizes changed lines, drops lines
    /// that lost all their strokes, then evaluates.
    private func analyzeDrawing() {
        guard result == nil, let layout = canvas.layout else { return }
        let strokes = canvas.drawing.strokes
        if let first = strokes.lazy.map(\.path.creationDate).min() {
            startDate = min(startDate ?? first, first)
            scheduleTimer()
        }
        let basisEnd = Self.latestStrokeEnd(strokes)

        var byLine: [Int: [PKStroke]] = [:]
        for stroke in strokes {
            guard let line = canvas.lineAssignments[stroke.id] else { continue }
            byLine[line, default: []].append(stroke)
        }

        for (line, lineStrokes) in byLine {
            let signature = LineSignature(lineStrokes)
            if entries[line]?.signature == signature { continue }
            var entry = entries[line] ?? LineEntry(signature: signature)
            entry.signature = signature
            if let cached = recognitionCache[LineKey(line: line, signature: signature)] {
                // Strokes seen before: reuse the result, and keep in-flight
                // work for other strokes from publishing over it.
                pipelines[line]?.barrier(showing: .idle)
                entry.result = CachedLine(line: cached, signature: signature, basisEnd: basisEnd)
            } else {
                generation += 1
                pipeline(forLine: line).submit(
                    LineJob(lineIndex: line, strokes: lineStrokes, signature: signature,
                            lineHeight: layout.lineHeight, basisEnd: basisEnd),
                    revision: generation)
            }
            entries[line] = entry
        }
        for line in entries.keys where byLine[line] == nil {
            entries[line] = nil
            pipelines.removeValue(forKey: line)?.barrier(showing: .idle)
        }
        evaluate()
    }

    private func pipeline(forLine line: Int) -> AnalysisPipeline<LineJob, WrittenLine> {
        if let existing = pipelines[line] { return existing }
        let created = AnalysisPipeline<LineJob, WrittenLine>(policy: .coalesceNewest) { [weak self] job, _, publish in
            guard let self else { return }
            let recognized = try await LineRecognizer(recognizer: self.strokeRecognizer)
                .recognize(lineIndex: job.lineIndex, strokes: job.strokes, lineHeight: job.lineHeight)
            try Task.checkCancellation()
            if publish(recognized) { self.lineRecognized(recognized, for: job) }
        }
        pipelines[line] = created
        return created
    }

    private func lineRecognized(_ line: WrittenLine, for job: LineJob) {
        if recognitionCache.count >= Self.recognitionCacheLimit { recognitionCache = [:] }
        recognitionCache[LineKey(line: job.lineIndex, signature: job.signature)] = line
        guard result == nil, var entry = entries[job.lineIndex] else { return }
        entry.result = CachedLine(line: line, signature: job.signature, basisEnd: job.basisEnd)
        entries[job.lineIndex] = entry
        evaluate()
    }

    // MARK: Evaluation

    /// The snapshot of everything recognized so far.
    func currentSnapshot() -> WritingSnapshot {
        let applyVision = settings.visionLeniency
        let lines = entries.keys.sorted().compactMap { index -> WrittenLine? in
            guard var line = entries[index]?.result?.line else { return nil }
            line.index = index
            if applyVision {
                for w in line.words.indices where !line.words[w].strokeIDs.isEmpty {
                    guard let alternatives = visionAlternatives[Set(line.words[w].strokeIDs)] else { continue }
                    // Vision found nothing: the word's own text marks it as checked.
                    line.words[w].alternatives = alternatives.isEmpty ? [line.words[w].text] : alternatives
                }
            }
            return line
        }
        // Lines after a line still being read count as pending too: until it
        // is current, words written on it may look skipped, and first
        // attempts must not be recorded from that.
        var pending = pendingLines
        if let first = pending.min() { pending.formUnion(entries.keys.filter { $0 > first }) }
        return WritingSnapshot(lines: lines, activeLineIndex: canvas.lineOfLastStroke,
                               activeStrokeID: canvas.drawing.strokes.last?.id,
                               pendingLineIndices: pending)
    }

    /// Evaluates the current snapshot. A complete passage finishes the test
    /// in passage mode and moves on to the next passage in timed mode.
    func evaluate() {
        guard result == nil, !timeIsUp else { return }
        var evaluated = session
        let state = evaluated.evaluate(currentSnapshot(), settings: settings)
        match = state
        if state.isComplete {
            // Finish only on current recognition of every line: a line still
            // being read could change the result. The end time comes from the
            // strokes, so waiting costs the writer nothing. A complete
            // evaluation settles every word, so its first-attempt records are
            // kept only once no line is pending.
            guard pendingLines.isEmpty else { return }
            session = evaluated
            if timeLimit == nil {
                finish()
            } else {
                appendNextPassage()
                evaluate()
            }
        } else {
            session = evaluated
            if settings.visionLeniency { requestVision(for: state.wordsNeedingVision) }
        }
    }

    // MARK: Timed mode

    /// Arms the timer for the current deadline (again if the start moved).
    private func scheduleTimer() {
        guard result == nil, let deadline, deadline != timerDeadline else { return }
        timerTask?.cancel()
        timerDeadline = deadline
        let sleep = sleep
        timerTask = Task { [weak self] in
            await sleep(deadline)
            guard !Task.isCancelled else { return }
            await self?.timeUp()
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
        timerDeadline = nil
    }

    /// Freezes the paper at once, lets lines written before the deadline
    /// finish recognition, then scores everything written as locked (no open
    /// word) and finishes.
    private func timeUp() async {
        guard result == nil, !timeIsUp, timeLimit != nil else { return }
        timeIsUp = true
        canvas.isWritingEnabled = false
        await waitForLineRecognition()
        // Reset, New passage or a mode change cancelled this run meanwhile.
        guard !Task.isCancelled, result == nil else { return }
        var snapshot = currentSnapshot()
        snapshot.activeLineIndex = nil
        snapshot.activeStrokeID = nil
        var evaluated = session
        match = evaluated.evaluate(snapshot, settings: settings)
        session = evaluated
        finish()
    }

    // MARK: Finish

    private func finish() {
        if let timeLimit {
            result = session.tally(reachedOnly: true).result(
                passage: passage, mode: mode, duration: timeLimit,
                passagesCompleted: session.passagesCompleted, settings: settings)
        } else {
            let end = entries.values.compactMap { $0.result?.basisEnd }.max()
                ?? Self.latestStrokeEnd(canvas.drawing.strokes) ?? now()
            let start = startDate ?? end
            result = session.result(duration: end.timeIntervalSince(start), mode: mode, settings: settings)
        }
        canvas.isWritingEnabled = false
        for pipeline in pipelines.values { pipeline.barrier(showing: .idle) }
        cancelVision()
    }

    /// The end of the latest stroke: touch-down plus its last point's offset.
    static func strokeEnd(_ stroke: PKStroke) -> Date {
        stroke.path.creationDate.addingTimeInterval(stroke.path.last?.timeOffset ?? 0)
    }

    static func latestStrokeEnd(_ strokes: [PKStroke]) -> Date? {
        strokes.lazy.map(strokeEnd).max()
    }

    // MARK: Settings

    private func settingsChanged(from old: SinglePlayerSettings) {
        guard settings != old else { return }
        if let defaults { SettingsStorage.save(settings, to: defaults) }
        if canvas.fingerWriting != settings.fingerWriting { canvas.fingerWriting = settings.fingerWriting }
        canvas.autoSwitchToPen = settings.autoSwitchToPen
        if settings.visionCandidateLimit != old.visionCandidateLimit { visionAlternatives = [:] }
        if !settings.visionLeniency { cancelVision() }
        if settings.mode != old.mode {
            // A test's mode is fixed: a new mode starts over on the current passage.
            startTest(with: passage)
        } else if settings.coloring != old.coloring || settings.visionLeniency != old.visionLeniency
            || settings.visionCandidateLimit != old.visionCandidateLimit {
            evaluate()
        }
    }

    // MARK: Vision leniency

    private func requestVision(for words: [[UUID]]) {
        for ids in words {
            let key = Set(ids)
            guard visionAlternatives[key] == nil, visionRunning != key,
                  !visionQueue.contains(where: { Set($0) == key }) else { continue }
            visionQueue.append(ids)
        }
        startNextVisionJob()
    }

    /// One Vision job at a time; results for strokes that changed meanwhile
    /// are dropped.
    private func startNextVisionJob() {
        guard visionTask == nil, settings.visionLeniency, result == nil else { return }
        while !visionQueue.isEmpty {
            let ids = visionQueue.removeFirst()
            let key = Set(ids)
            guard visionAlternatives[key] == nil else { continue }
            let drawing = canvas.drawing
            let strokes = drawing.strokes.filter { key.contains($0.id) }
            guard strokes.count == key.count, let image = InkImage(strokes: strokes)?.cgImage else { continue }
            let signature = LineSignature(strokes)
            let visionSettings = VisionSettings(candidateCount: settings.visionCandidateLimit)
            let recognizer = textRecognizer
            let token = visionToken
            visionRunning = key
            visionRequestCount += 1
            visionTask = Task { [weak self] in
                let regions = try? await recognizer.recognize(image, settings: visionSettings)
                guard let self, token == self.visionToken else { return }
                self.visionTask = nil
                self.visionRunning = nil
                let current = self.canvas.drawing.strokes.filter { key.contains($0.id) }
                if !Task.isCancelled, LineSignature(current) == signature {
                    self.visionAlternatives[key] = Self.candidates(from: regions ?? [])
                    self.evaluate()
                }
                self.startNextVisionJob()
            }
            return
        }
    }

    private func cancelVision() {
        visionToken += 1
        visionTask?.cancel()
        visionTask = nil
        visionRunning = nil
        visionQueue = []
    }

    /// Candidate readings, best first: with several regions (a word Vision
    /// split), the regions' top strings joined left to right come first; then
    /// every region's candidates by rank.
    static func candidates(from regions: [VisionRegion]) -> [String] {
        let ordered = regions.sorted { $0.bounds.minX < $1.bounds.minX }
        var out: [String] = []
        func add(_ s: String) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !out.contains(trimmed) { out.append(trimmed) }
        }
        if ordered.count > 1 {
            let tops = ordered.compactMap { $0.candidates.first?.string }
            add(tops.joined())
            add(tops.joined(separator: " "))
        }
        let depth = ordered.map(\.candidates.count).max() ?? 0
        for rank in 0..<depth {
            for region in ordered where rank < region.candidates.count { add(region.candidates[rank].string) }
        }
        return out
    }
}

/// What identifies a line's strokes for re-recognition: ordered stroke IDs
/// plus each stroke's point count, render bounds and mask. Stroke IDs survive
/// undo and redo (`InkDocument.detached` keeps the strokes), so an unchanged
/// line keeps its signature.
struct LineSignature: Hashable, Sendable {
    struct Stroke: Hashable, Sendable {
        let id: UUID
        let points: Int
        let bounds: [Double]
        let masked: Bool
    }

    let strokes: [Stroke]

    init(_ strokes: [PKStroke]) {
        self.strokes = strokes.map { stroke in
            let b = stroke.renderBounds
            return Stroke(id: stroke.id, points: stroke.path.count,
                          bounds: [b.minX, b.minY, b.maxX, b.maxY].map(Double.init),
                          masked: stroke.mask != nil)
        }
    }
}

/// `SinglePlayerSettings` in UserDefaults, one key per field.
enum SettingsStorage {
    private static let prefix = "singlePlayer."
    /// The mode's key (a `TestMode.rawValue`); the home screen's mode picker
    /// writes it too.
    static let modeKey = prefix + "mode"

    static func load(from defaults: UserDefaults) -> SinglePlayerSettings {
        var s = SinglePlayerSettings()
        if let v = defaults.string(forKey: modeKey), let mode = TestMode(rawValue: v) { s.mode = mode }
        if let v = defaults.object(forKey: prefix + "visibleLines") as? Int {
            s.visibleLines = min(SinglePlayerSettings.visibleLineRange.upperBound,
                                 max(SinglePlayerSettings.visibleLineRange.lowerBound, v))
        }
        if let v = defaults.string(forKey: prefix + "coloring"), let mode = WordColoringMode(rawValue: v) { s.coloring = mode }
        if let v = defaults.object(forKey: prefix + "visionLeniency") as? Bool { s.visionLeniency = v }
        if let v = defaults.object(forKey: prefix + "visionCandidateLimit") as? Int { s.visionCandidateLimit = max(1, v) }
        if let v = defaults.object(forKey: prefix + "showLiveStats") as? Bool { s.showLiveStats = v }
        if let v = defaults.object(forKey: prefix + "fingerWriting") as? Bool { s.fingerWriting = v }
        if let v = defaults.object(forKey: prefix + "autoSwitchToPen") as? Bool { s.autoSwitchToPen = v }
        if let v = defaults.object(forKey: prefix + "showDebugInfo") as? Bool { s.showDebugInfo = v }
        return s
    }

    static func save(_ s: SinglePlayerSettings, to defaults: UserDefaults) {
        defaults.set(s.mode.rawValue, forKey: modeKey)
        defaults.set(s.visibleLines, forKey: prefix + "visibleLines")
        defaults.set(s.coloring.rawValue, forKey: prefix + "coloring")
        defaults.set(s.visionLeniency, forKey: prefix + "visionLeniency")
        defaults.set(s.visionCandidateLimit, forKey: prefix + "visionCandidateLimit")
        defaults.set(s.showLiveStats, forKey: prefix + "showLiveStats")
        defaults.set(s.fingerWriting, forKey: prefix + "fingerWriting")
        defaults.set(s.autoSwitchToPen, forKey: prefix + "autoSwitchToPen")
        defaults.set(s.showDebugInfo, forKey: prefix + "showDebugInfo")
    }
}
