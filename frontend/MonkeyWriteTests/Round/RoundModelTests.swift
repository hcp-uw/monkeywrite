import PencilKit
import XCTest
@testable import MonkeyWrite

@MainActor
final class RoundModelTests: XCTestCase {
    // MARK: Per-line recognition

    func testOnlyChangedLinesAreRecognizedAgain() async {
        let h = RoundHarness()
        let line0 = h.write([(0, 0, "the"), (0, 1, "quick")])
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.recognizer.preparedCount(containing: line0.map(\.id)), 1)

        let brown = h.write(line: 1, slot: 0, "brown")
        await h.model.waitForAnalysis()
        let fox = h.write(line: 1, slot: 1, "fox")
        await h.model.waitForAnalysis()

        XCTAssertEqual(h.recognizer.preparedCount(containing: line0.map(\.id)), 1, "Line 0 never changed")
        XCTAssertEqual(h.recognizer.preparedCount(containing: [brown.id]), 2, "Line 1 changed twice")
        XCTAssertEqual(h.recognizer.preparedCount(containing: [fox.id]), 1)
        XCTAssertEqual(h.statuses(), [.correct, .correct, .correct, .open, .pending, .pending])
        XCTAssertEqual(h.model.match.cursorWordIndex, 3)
        XCTAssertEqual(h.model.recognizedLines[1]?.words.map(\.text), ["brown", "fox"])
        XCTAssertTrue(h.model.pendingLines.isEmpty)
    }

    func testErasingAWordOnAnEarlierLineReRecognizesItAndItRelocks() async {
        let h = RoundHarness()
        let words = h.write([(0, 0, "the"), (0, 1, "qick"), (1, 0, "brown")])
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.statuses()[1], .incorrect)
        XCTAssertEqual(h.model.firstAttempt[1], false)
        let line1Recognitions = h.recognizer.preparedCount(containing: [words[2].id])

        h.erase([words[1]])
        h.write(line: 0, slot: 1, "quick")
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.statuses()[1], .open, "The rewritten word is the newest stroke's word")
        XCTAssertEqual(h.statuses()[2], .correct)
        XCTAssertEqual(h.model.match.cursorWordIndex, 3, "The cursor stays at the furthest progress")
        XCTAssertEqual(h.recognizer.preparedCount(containing: [words[2].id]), line1Recognitions,
                       "Line 1 is not re-read")

        h.write(line: 1, slot: 1, "fox")
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.statuses()[1], .correct, "Fixed word re-locks as correct")
        XCTAssertEqual(h.model.firstAttempt[1], false, "First attempt stays failed")

        h.write([(1, 2, "jumps"), (1, 3, "over")])
        await h.model.waitForAnalysis()
        let result = try! XCTUnwrap(h.model.result)
        XCTAssertEqual(result.wordsCorrected, 1)
        XCTAssertEqual(result.accuracy, 5.0 / 6.0, accuracy: 1e-9)
    }

    // MARK: Completion and timing

    private func finishPassage(delay: Duration) async -> (RoundHarness, TestResult?) {
        let h = RoundHarness()
        h.recognizer.delay = delay
        h.write([(0, 0, "the"), (0, 1, "quick"), (0, 2, "brown"), (0, 3, "fox"), (0, 4, "jumps")])
        await h.model.waitForAnalysis()
        XCTAssertNil(h.model.result)
        h.write(line: 0, slot: 5, "over")
        await h.model.waitForAnalysis()
        return (h, h.model.result)
    }

    func testCompletionFreezesThePaperAndShowsTheResult() async throws {
        let (h, result) = await finishPassage(delay: .zero)
        let r = try XCTUnwrap(result)
        XCTAssertTrue(h.model.match.isComplete)
        XCTAssertFalse(h.model.canvas.isWritingEnabled)
        XCTAssertEqual(r.correctWords, 6)
        XCTAssertEqual(r.accuracy, 1)
        XCTAssertGreaterThan(r.wpm, 0)
        XCTAssertEqual(h.model.wordsDone, 6)
        XCTAssertEqual(h.model.elapsed(at: .distantFuture), r.duration, "The clock stops at the end")

        let before = h.model.match
        h.write(line: 1, slot: 0, "extra")
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.model.match, before, "Nothing is analyzed after the end")
    }

    func testDurationIsFirstStrokeStartToLastStrokeEndRegardlessOfRecognitionDelay() async throws {
        let (_, fast) = await finishPassage(delay: .zero)
        let (_, slow) = await finishPassage(delay: .milliseconds(250))
        // Six strokes one second apart, each 0.5 s long.
        XCTAssertEqual(try XCTUnwrap(fast).duration, 5.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(slow).duration, 5.5, accuracy: 1e-6)
    }

    func testCompletionWaitsForLinesStillBeingRecognized() async throws {
        let h = RoundHarness(passage: RoundHarness.passages[1])   // "a lazy dog"
        let gate = Gate<Void>()
        h.recognizer.gate = gate
        h.write(line: 0, slot: 0, "a")
        gate.release(0, ())
        await eventually(h.model.recognizedLines[0] != nil)
        h.write(line: 0, slot: 1, "lazy")                  // line 0 re-read: #1, held
        await eventually(h.recognizer.prepared.count == 2)
        let dog = h.write(line: 1, slot: 0, "dog")          // #2, held
        await eventually(h.recognizer.prepared.count == 3)
        gate.release(2, ())
        await eventually(h.model.recognizedLines[1] != nil)
        XCTAssertTrue(h.model.match.isComplete, "The last word is correct")
        XCTAssertEqual(h.model.pendingLines, [0])
        XCTAssertNil(h.model.result, "Line 0 is still being read")
        XCTAssertTrue(h.model.canvas.isWritingEnabled)

        try await Task.sleep(for: .milliseconds(200))   // recognition latency
        gate.release(1, ())
        await h.model.waitForAnalysis()
        let result = try XCTUnwrap(h.model.result)
        XCTAssertEqual(result.correctWords, 3)
        XCTAssertEqual(result.missedWords, 0)
        XCTAssertEqual(result.accuracy, 1, "The early complete evaluation recorded no failed attempts")
        XCTAssertEqual(result.duration, RoundModel.strokeEnd(dog).timeIntervalSince(h.model.startDate!), accuracy: 1e-6,
                       "The wait does not count")
    }

    func testStartIsTheEarliestStrokeEverDrawn() async {
        let h = RoundHarness()
        let first = h.write(line: 0, slot: 0, "the")
        h.write(line: 0, slot: 1, "quick")
        XCTAssertEqual(h.model.startDate, first.path.creationDate)
        h.erase([first])
        XCTAssertEqual(h.model.startDate, first.path.creationDate, "Erasing the first stroke keeps the start")
        await h.model.waitForAnalysis()
    }

    // MARK: Reset, new passage, restart

    func testResetClearsTheTest() async {
        let h = RoundHarness()
        h.write([(0, 0, "the"), (0, 1, "quick")])
        await h.model.waitForAnalysis()
        h.model.reset()
        XCTAssertTrue(h.model.canvas.drawing.strokes.isEmpty)
        XCTAssertNil(h.model.startDate)
        XCTAssertTrue(h.model.recognizedLines.isEmpty)
        XCTAssertEqual(h.statuses(), Array(repeating: .pending, count: 6))
        XCTAssertEqual(h.model.firstAttempt, Array(repeating: nil, count: 6))
        XCTAssertTrue(h.model.canvas.canUndo, "Reset is undoable")
        XCTAssertEqual(h.model.elapsed(at: .now), 0)
        XCTAssertNil(h.model.liveWPM(elapsed: 10))
    }

    func testUndoRightAfterResetRestoresInkAndTestState() async {
        let h = RoundHarness()
        h.write([(0, 0, "the"), (0, 1, "qick"), (1, 0, "brown")])
        await h.model.waitForAnalysis()
        let ids = h.model.canvas.drawing.strokes.map(\.id)
        let match = h.model.match, start = h.model.startDate, history = h.model.firstAttempt
        let recognitions = h.recognizer.prepared.count

        h.model.reset()
        h.model.undo()
        XCTAssertEqual(h.model.canvas.drawing.strokes.map(\.id), ids)
        XCTAssertEqual(h.model.match, match)
        XCTAssertEqual(h.model.startDate, start)
        XCTAssertEqual(h.model.firstAttempt, history)
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.recognizer.prepared.count, recognitions, "Nothing is re-recognized")
        XCTAssertEqual(h.model.match, match)

        h.model.redo()
        XCTAssertEqual(h.statuses(), Array(repeating: .pending, count: 6), "Redo shows the reset again")
        XCTAssertNil(h.model.startDate)
        h.model.undo()
        XCTAssertEqual(h.model.match, match)
        XCTAssertEqual(h.model.firstAttempt, history)

        // A stroke on the reset paper discards the saved test.
        h.model.reset()
        let fresh = h.write(line: 0, slot: 0, "the")
        await h.model.waitForAnalysis()
        h.model.undo()
        XCTAssertTrue(h.model.canvas.drawing.strokes.isEmpty)
        XCTAssertFalse(h.model.canvas.canUndo)
        XCTAssertEqual(h.statuses(), Array(repeating: .pending, count: 6))
        XCTAssertEqual(h.model.firstAttempt, Array(repeating: nil, count: 6))
        XCTAssertEqual(h.model.startDate, fresh.path.creationDate, "The start is the earliest stroke ever drawn")
    }

    func testNewPassageAndRestart() async {
        let h = RoundHarness()
        h.write([(0, 0, "the"), (0, 1, "quick")])
        await h.model.waitForAnalysis()
        h.model.newPassage()
        XCTAssertEqual(h.model.passage.id, "b")
        XCTAssertTrue(h.model.canvas.drawing.strokes.isEmpty)
        XCTAssertFalse(h.model.canvas.canUndo, "A new passage is a fresh test")
        XCTAssertEqual(h.model.match.words.count, 3)
        XCTAssertNil(h.model.startDate)

        h.write([(0, 0, "a"), (0, 1, "lazy"), (0, 2, "dog")])
        await h.model.waitForAnalysis()
        XCTAssertNotNil(h.model.result)
        h.model.restart()
        XCTAssertEqual(h.model.passage.id, "b")
        XCTAssertNil(h.model.result)
        XCTAssertTrue(h.model.canvas.isWritingEnabled)
        XCTAssertEqual(h.statuses(), [.pending, .pending, .pending])
    }

    func testVisibleLinesApplyOnlyToTheNextTest() async {
        let h = RoundHarness()
        h.write(line: 0, slot: 0, "the")
        h.model.settings.visibleLines = 7
        XCTAssertEqual(h.model.canvas.visibleLines, 5)
        XCTAssertEqual(h.model.activeTestVisibleLines, 5)
        XCTAssertTrue(h.model.linesApplyNextTest)
        let lineHeight = h.layout.lineHeight

        h.model.reset()
        XCTAssertEqual(h.model.canvas.visibleLines, 7)
        XCTAssertEqual(h.model.activeTestVisibleLines, 7)
        XCTAssertFalse(h.model.linesApplyNextTest)
        XCTAssertLessThan(h.layout.lineHeight, lineHeight)

        h.model.settings.visibleLines = 4
        h.model.newPassage()
        XCTAssertEqual(h.model.canvas.visibleLines, 4)
        await h.model.waitForAnalysis()
    }

    // MARK: Ordering

    func testResultForStrokesThatAreGoneNeverOverwritesTheCurrentOne() async {
        let h = RoundHarness()
        let gate = Gate<Void>()
        h.recognizer.gate = gate
        let teh = h.write(line: 0, slot: 0, "teh")
        gate.release(0, ())
        await eventually(h.model.recognizedLines[0] != nil)

        // Rewrite the word (recognition #1 held), then undo back to "teh".
        let the = h.stroke(line: 0, slot: 0)
        h.recognizer.text[the.id] = "the"
        var rewritten = h.model.canvas.drawing
        rewritten.strokes = [the]
        h.model.canvas.drawingChanged(rewritten)
        await eventually(h.recognizer.prepared.count == 2)
        XCTAssertEqual(h.model.pendingLines, [0])
        h.model.undo()
        XCTAssertEqual(h.model.canvas.drawing.strokes.map(\.id), [teh.id])
        XCTAssertEqual(h.model.recognizedLines[0]?.words.map(\.text), ["teh"], "Earlier result reused")
        XCTAssertTrue(h.model.pendingLines.isEmpty)

        gate.release(1, ())
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.model.recognizedLines[0]?.words.map(\.text), ["teh"], "The late result is dropped")
        XCTAssertEqual(h.recognizer.prepared.count, 2)
    }

    func testEditsDuringRecognitionCoalesceToTheNewest() async {
        let h = RoundHarness()
        let gate = Gate<Void>()
        h.recognizer.gate = gate
        h.write(line: 0, slot: 0, "the")
        await eventually(h.recognizer.prepared.count == 1)
        h.write(line: 0, slot: 1, "quick")
        h.write(line: 0, slot: 2, "brown")
        gate.release(0, ())
        await eventually(h.model.recognizedLines[0] != nil)
        XCTAssertEqual(h.model.recognizedLines[0]?.words.map(\.text), ["the"])
        XCTAssertEqual(h.model.pendingLines, [0], "A stale result shows while the newest is read")
        XCTAssertEqual(h.statuses()[0], .open)

        await eventually(h.recognizer.prepared.count == 2)
        gate.release(1, ())
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.recognizer.prepared.count, 2, "Only the newest waiting request ran")
        XCTAssertEqual(h.model.recognizedLines[0]?.words.map(\.text), ["the", "quick", "brown"])
        XCTAssertTrue(h.model.pendingLines.isEmpty)
    }

    func testNoFirstAttemptIsRecordedPastALineStillBeingRead() async {
        let h = RoundHarness()
        let gate = Gate<Void>()
        h.recognizer.gate = gate
        h.write([(0, 0, "the"), (0, 1, "quick")])
        gate.release(0, ())
        await eventually(h.model.recognizedLines[0] != nil)
        h.write(line: 1, slot: 0, "brown")                         // #1, held
        await eventually(h.recognizer.prepared.count == 2)
        h.write([(2, 0, "fox"), (2, 1, "jumps")])                  // #2
        await eventually(h.recognizer.prepared.count == 3)
        gate.release(2, ())
        await eventually(h.model.recognizedLines[2] != nil)
        XCTAssertEqual(h.statuses()[2], .missed, "Shown as skipped while line 1 is read")
        XCTAssertNil(h.model.firstAttempt[2], "but not recorded as a failed attempt")
        XCTAssertNil(h.model.firstAttempt[3])

        gate.release(1, ())
        await h.model.waitForAnalysis()
        XCTAssertEqual(Array(h.model.firstAttempt.prefix(4)), [true, true, true, true])
        XCTAssertEqual(h.statuses(), [.correct, .correct, .correct, .correct, .open, .pending])
    }

    func testRewritingAMiddleWordMakesItTheOpenWord() async {
        let h = RoundHarness()
        let words = h.write([(0, 0, "the"), (0, 1, "quick"), (0, 2, "brown")])
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.model.firstAttempt[1], true)
        h.erase([words[1]])
        h.write(line: 0, slot: 1, "qu")
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.model.recognizedLines[0]?.words.map(\.text), ["the", "qu", "brown"])
        XCTAssertEqual(h.statuses(), [.correct, .open, .correct, .pending, .pending, .pending],
                       "The word holding the newest stroke is open, not the line's last word")
        XCTAssertEqual(h.model.match.words[1].chars.prefix(2), [.correct, .correct], "Live coloring of the open word")
        XCTAssertEqual(h.model.match.cursorWordIndex, 3, "The cursor stays at the furthest progress")
        XCTAssertEqual(h.model.firstAttempt[1], true, "The rewrite records nothing")
    }

    func testTheOpenUnderlineStaysWhileANewLineIsStillBeingRead() async {
        let h = RoundHarness()
        let gate = Gate<Void>()
        h.recognizer.gate = gate
        h.write(line: 0, slot: 0, "the")
        gate.release(0, ())
        await eventually(h.model.recognizedLines[0] != nil)
        h.write(line: 1, slot: 0, "quick")                   // #1, held
        await eventually(h.recognizer.prepared.count == 2)
        XCTAssertNil(h.model.recognizedLines[1])
        XCTAssertEqual(h.statuses(), [.correct, .open, .pending, .pending, .pending, .pending],
                       "The expected word is underlined before its line is read")
        XCTAssertEqual(h.model.match.words[1].chars, Array(repeating: .current, count: 5), "Shown neutral")
        XCTAssertNil(h.model.firstAttempt[1])
        gate.release(1, ())
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.statuses()[1], .open)
    }

    func testErasingEveryStrokeOfALineDropsItAtOnce() async {
        let h = RoundHarness()
        h.write(line: 0, slot: 0, "the")
        let quick = h.write(line: 1, slot: 0, "quick")
        await h.model.waitForAnalysis()
        h.erase([quick])
        XCTAssertNil(h.model.recognizedLines[1])
        XCTAssertEqual(h.statuses()[1], .pending)
        XCTAssertEqual(h.statuses()[0], .open)
        await h.model.waitForAnalysis()
    }

    // MARK: Vision leniency

    private func misread(_ h: RoundHarness) async {
        h.vision.answer = [VisionRegion(bounds: CGRect(x: 0, y: 0, width: 1, height: 1), candidates: [
            VisionCandidate(string: "qvick", confidence: 0.6), VisionCandidate(string: "quick", confidence: 0.4),
        ])]
        h.write([(0, 0, "the"), (0, 1, "qvick"), (1, 0, "brown")])
        await h.model.waitForAnalysis()
    }

    func testVisionLeniencyOffNeverRunsVision() async {
        let h = RoundHarness()
        await misread(h)
        XCTAssertEqual(h.vision.calls, 0)
        XCTAssertEqual(h.statuses()[1], .incorrect)
    }

    func testVisionLeniencyRescuesAMisreadWordOnce() async throws {
        var settings = SinglePlayerSettings()
        settings.visionLeniency = true
        let h = RoundHarness(settings: settings)
        await misread(h)
        XCTAssertEqual(h.vision.calls, 1)
        XCTAssertEqual(h.vision.lastSettings?.candidateCount, settings.visionCandidateLimit)
        XCTAssertEqual(h.statuses()[1], .correct)
        XCTAssertTrue(h.model.match.words[1].assisted)
        XCTAssertEqual(h.model.firstAttempt[1], true, "Vision upgrades the first attempt")

        h.write(line: 1, slot: 1, "fox")
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.vision.calls, 1, "Cached alternatives are reused")
        h.write([(1, 2, "jumps"), (1, 3, "over")])
        await h.model.waitForAnalysis()
        let result = try XCTUnwrap(h.model.result)
        XCTAssertEqual(result.assistedWords, 1)
        XCTAssertTrue(result.visionLeniencyEnabled)
        XCTAssertEqual(result.accuracy, 1)
    }

    func testTurningVisionLeniencyOnLaterChecksLockedWords() async {
        let h = RoundHarness()
        await misread(h)
        XCTAssertEqual(h.statuses()[1], .incorrect)
        h.model.settings.visionLeniency = true
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.vision.calls, 1)
        XCTAssertEqual(h.statuses()[1], .correct)
    }

    func testVisionCandidatesJoinSplitRegions() {
        let regions = [
            VisionRegion(bounds: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                         candidates: [VisionCandidate(string: "ck", confidence: 1)]),
            VisionRegion(bounds: CGRect(x: 0, y: 0, width: 0.5, height: 1),
                         candidates: [VisionCandidate(string: "qui", confidence: 1), VisionCandidate(string: "gui", confidence: 1)]),
        ]
        XCTAssertEqual(RoundModel.candidates(from: regions), ["quick", "qui ck", "qui", "ck", "gui"])
        XCTAssertEqual(RoundModel.candidates(from: []), [])
    }

    // MARK: Settings and stats

    func testSettingsPersistAndApply() {
        let suite = "round-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let h = RoundHarness(defaults: defaults)
        h.model.settings.coloring = .neutralUntilLocked
        h.model.settings.showLiveStats = false
        h.model.settings.fingerWriting = true
        h.model.settings.visibleLines = 6
        XCTAssertTrue(h.model.canvas.fingerWriting, "Finger writing applies at once")

        let reloaded = RoundModel(strokeRecognizer: ScriptedStrokeRecognizer(), textRecognizer: FakeTextImageRecognizer(),
                                  passageSource: FixedPassages(passages: RoundHarness.passages), defaults: defaults)
        XCTAssertEqual(reloaded.settings, h.model.settings)
        XCTAssertEqual(reloaded.canvas.visibleLines, 6)
        XCTAssertTrue(reloaded.canvas.fingerWriting)
    }

    func testLiveColoringChangeReEvaluatesAtOnce() async {
        var settings = SinglePlayerSettings()
        settings.coloring = .neutralUntilLocked
        let h = RoundHarness(settings: settings)
        h.write(line: 0, slot: 0, "thx")
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.model.match.words[0].chars, [.current, .current, .current])
        h.model.settings.coloring = .live
        XCTAssertEqual(h.model.match.words[0].chars.first, .correct)
    }

    func testLiveStats() async {
        let h = RoundHarness()
        XCTAssertEqual(h.model.wordsDone, 0)
        XCTAssertEqual(h.model.elapsed(at: .now), 0)
        let first = h.write(line: 0, slot: 0, "the")
        await h.model.waitForAnalysis()
        XCTAssertNil(h.model.liveWPM(elapsed: 5), "No speed before a word locks")
        XCTAssertEqual(h.model.elapsed(at: first.path.creationDate.addingTimeInterval(3)), 3, accuracy: 1e-9)
        h.write(line: 0, slot: 1, "quick")
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.model.wordsDone, 1)
        // "the quick " = 10 chars (open word counts if correct) = 2 words in 0.5 min.
        XCTAssertEqual(h.model.liveWPM(elapsed: 30) ?? 0, 4, accuracy: 1e-9)
    }

    func testModeAndPenSettingsPersist() {
        let suite = "round-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = SettingsStorage.load(from: defaults)
        XCTAssertEqual(fresh.mode, .oneMinute, "Sixty seconds is the default")
        XCTAssertEqual(fresh.coloring, .live, "Live coloring is the default")
        XCTAssertTrue(fresh.autoSwitchToPen)

        let h = RoundHarness(mode: .oneMinute, defaults: defaults)
        h.model.settings.autoSwitchToPen = false
        XCTAssertFalse(h.model.canvas.autoSwitchToPen, "Applies at once")
        let reloaded = RoundModel(strokeRecognizer: ScriptedStrokeRecognizer(), textRecognizer: FakeTextImageRecognizer(),
                                  passageSource: FixedPassages(passages: RoundHarness.passages), defaults: defaults)
        XCTAssertEqual(reloaded.settings.mode, .oneMinute)
        XCTAssertEqual(reloaded.mode, .oneMinute)
        XCTAssertFalse(reloaded.settings.autoSwitchToPen)
        XCTAssertFalse(reloaded.canvas.autoSwitchToPen)
    }

    func testHomeScreenModeKeyIsTheSettingsKey() {
        let suite = "round-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SettingsStorage.modeKey, "singlePlayer.mode")
        defaults.set("timed:60", forKey: "singlePlayer.mode")
        XCTAssertEqual(SettingsStorage.load(from: defaults).mode, .timed(seconds: 60))
        // What the home screen writes.
        defaults.set(TestMode.passage.rawValue, forKey: SettingsStorage.modeKey)
        XCTAssertEqual(defaults.string(forKey: SettingsStorage.modeKey), "passage")
        XCTAssertEqual(SettingsStorage.load(from: defaults).mode, .passage)
        for bad in ["timed:0", "timed:x", "words"] { XCTAssertNil(TestMode(rawValue: bad)) }
        defaults.set("timed:0", forKey: SettingsStorage.modeKey)
        XCTAssertEqual(SettingsStorage.load(from: defaults).mode, .oneMinute, "An unknown value falls back to the default")
    }

    // MARK: Timed mode

    func testTimedModeAppendsTheNextPassageOnTheSamePaper() async {
        let h = RoundHarness(mode: .oneMinute)
        XCTAssertEqual(h.model.timeLimit, 60)
        let strokes = h.write([(0, 0, "the"), (0, 1, "quick"), (0, 2, "brown"), (0, 3, "fox"), (0, 4, "jumps"), (0, 5, "over")])
        await h.model.waitForAnalysis()
        let start = strokes[0].path.creationDate
        XCTAssertNil(h.model.result, "Completing a passage does not end a timed test")
        XCTAssertEqual(h.model.passages.map(\.id), ["a", "b"])
        XCTAssertEqual(h.model.passage.id, "a", "The passage the test started with")
        XCTAssertEqual(h.model.words.count, 9)
        XCTAssertEqual(h.model.passageStarts, [6])
        XCTAssertEqual(h.model.canvas.drawing.strokes.map(\.id), strokes.map(\.id), "The paper is kept")
        XCTAssertTrue(h.model.canvas.canUndo, "So is the undo history")
        XCTAssertTrue(h.model.canvas.isWritingEnabled)
        XCTAssertEqual(h.statuses(), [.correct, .correct, .correct, .correct, .correct, .open, .pending, .pending, .pending],
                       "The last word stays open until the next word is written")
        XCTAssertEqual(h.model.firstAttempt.prefix(6), [true, true, true, true, true, true], "Settled at completion")
        XCTAssertEqual(h.model.startDate, start)
        XCTAssertEqual(h.model.elapsed(at: start.addingTimeInterval(90)), 60, "Elapsed stops at the limit")
        // "the quick brown fox jumps over " = 31 chars (a space follows "over" now) in 0.5 min.
        XCTAssertEqual(h.model.liveWPM(elapsed: 30) ?? 0, 12.4, accuracy: 1e-9)

        // The next passage's first words, on the next paper line.
        h.write([(1, 0, "a"), (1, 1, "lazy")])
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.statuses(), [.correct, .correct, .correct, .correct, .correct, .correct, .correct, .open, .pending])
        XCTAssertEqual(h.model.wordsDone, 7)
        XCTAssertEqual(h.model.cursorPassage.id, "b")
        XCTAssertEqual(h.model.startDate, start)
        XCTAssertEqual(h.timer.deadlines, [start.addingTimeInterval(60)], "One timer for the whole test")

        // Reset stays undoable across the passage boundary.
        let match = h.model.match
        h.model.reset()
        XCTAssertEqual(h.model.passages.map(\.id), ["a"])
        XCTAssertNil(h.model.startDate)
        XCTAssertEqual(h.model.wordsDone, 0)
        h.model.undo()
        XCTAssertEqual(h.model.passages.map(\.id), ["a", "b"])
        XCTAssertEqual(h.model.match, match)
        XCTAssertEqual(h.model.startDate, start)
        await h.model.waitForAnalysis()
    }

    func testUndoPastThePassageBoundaryKeepsTheAppendedPassage() async {
        let h = RoundHarness(mode: .oneMinute)
        h.write([(0, 0, "the"), (0, 1, "quick"), (0, 2, "brown"), (0, 3, "fox"), (0, 4, "jumps")])
        await h.model.waitForAnalysis()
        h.write(line: 0, slot: 5, "over")
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.model.passages.count, 2)

        h.model.undo()
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.model.passages.map(\.id), ["a", "b"], "Once appended, a passage stays")
        XCTAssertEqual(h.statuses()[5], .pending)
        XCTAssertEqual(h.model.firstAttempt[5], true, "History is kept")
        h.model.redo()
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.statuses()[5], .open)
        XCTAssertEqual(h.model.passages.count, 2, "Nothing more is appended until the new text is complete")
        XCTAssertNil(h.model.result)
    }

    func testTimeUpEndsTheTestWithStatsOverEveryPassage() async throws {
        let h = RoundHarness(passage: RoundHarness.passages[1], mode: .oneMinute)   // "a lazy dog"
        h.write([(0, 0, "a"), (0, 1, "lazy"), (0, 2, "dog")])
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.model.passages.map(\.id), ["b", "a"])
        h.write([(1, 0, "the"), (1, 1, "brown"), (1, 2, "fxo")])
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.statuses()[6], .open)

        h.timer.fire()
        await h.model.waitForTimer()
        let r = try XCTUnwrap(h.model.result)
        XCTAssertFalse(h.model.canvas.isWritingEnabled)
        XCTAssertEqual(h.statuses(), [.correct, .correct, .correct, .correct, .missed, .correct, .incorrect, .pending, .pending],
                       "The open word is scored as locked")
        XCTAssertEqual(r.mode, .oneMinute)
        XCTAssertEqual(r.duration, 60)
        XCTAssertEqual(r.passage.id, "b", "The passage the test started with")
        XCTAssertEqual(r.passagesCompleted, 1)
        XCTAssertEqual(r.correctWords, 5)
        XCTAssertEqual(r.totalWords, 7, "3 + the 4 words reached; the untouched rest does not count")
        XCTAssertEqual(r.missedWords, 1)
        XCTAssertEqual(r.wordsCorrected, 0)
        XCTAssertEqual(r.accuracy, 5.0 / 7.0, accuracy: 1e-9)
        // Correct: "a lazy dog " (11) + "the " (4) + "brown " (6) = 21 chars; raw adds "fox " (4).
        XCTAssertEqual(r.wpm, 4.2, accuracy: 1e-9)
        XCTAssertEqual(r.rawWPM, 5, accuracy: 1e-9)
        XCTAssertEqual(h.model.wordsDone, 7)
        XCTAssertEqual(h.model.elapsed(at: .distantFuture), 60)

        h.model.restart()
        XCTAssertEqual(h.model.passages.map(\.id), ["b"], "Restart goes back to the first passage alone")
        XCTAssertNil(h.model.result)
        XCTAssertNil(h.model.startDate)
        XCTAssertTrue(h.model.canvas.isWritingEnabled)
        h.model.newPassage()
        XCTAssertEqual(h.model.passages.map(\.id), ["a"])
    }

    func testTimeUpWaitsForLinesStillBeingRecognized() async throws {
        let h = RoundHarness(mode: .oneMinute)
        let gate = Gate<Void>()
        h.recognizer.gate = gate
        h.write(line: 0, slot: 0, "the")
        gate.release(0, ())
        await eventually(h.model.recognizedLines[0] != nil)
        h.write(line: 0, slot: 1, "quick")                 // #1, held
        await eventually(h.recognizer.prepared.count == 2 && h.timer.deadlines.count == 1)

        h.timer.fire()
        await eventually(!h.model.canvas.isWritingEnabled)
        XCTAssertNil(h.model.result, "Line 0 is still being read")
        h.model.undo()
        XCTAssertEqual(h.model.canvas.drawing.strokes.count, 2, "The paper is frozen")

        gate.release(1, ())
        await h.model.waitForTimer()
        let r = try XCTUnwrap(h.model.result)
        XCTAssertEqual(r.correctWords, 2, "Words written before the deadline count")
        XCTAssertEqual(r.totalWords, 2)
        XCTAssertEqual(r.accuracy, 1)
        XCTAssertEqual(r.duration, 60)
        XCTAssertEqual(r.passagesCompleted, 0)
    }

    func testChangingTheModeStartsTheTestOver() async {
        let h = RoundHarness()
        h.write([(0, 0, "the"), (0, 1, "quick")])
        await h.model.waitForAnalysis()
        h.model.settings.mode = .oneMinute
        XCTAssertEqual(h.model.mode, .oneMinute)
        XCTAssertEqual(h.model.passage.id, "a", "Same passage")
        XCTAssertTrue(h.model.canvas.drawing.strokes.isEmpty)
        XCTAssertFalse(h.model.canvas.canUndo)
        XCTAssertNil(h.model.startDate)
        XCTAssertEqual(h.statuses(), Array(repeating: .pending, count: 6))

        let first = h.write(line: 0, slot: 0, "the")
        await h.model.waitForAnalysis()
        await eventually(h.timer.deadlines.count == 1)
        XCTAssertEqual(h.timer.deadlines, [first.path.creationDate.addingTimeInterval(60)])

        h.model.settings.mode = .passage
        XCTAssertEqual(h.model.mode, .passage)
        XCTAssertNil(h.model.timeLimit)
        h.timer.fire()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(h.model.result, "The timer of the old test was cancelled")
        XCTAssertTrue(h.model.canvas.isWritingEnabled)
    }

    func testUndoingAResetInTimedModeRearmsTheTimer() async throws {
        let h = RoundHarness(mode: .oneMinute)
        let first = h.write([(0, 0, "the"), (0, 1, "quick")])[0]
        await h.model.waitForAnalysis()
        await eventually(h.timer.deadlines.count == 1)
        h.model.reset()
        XCTAssertNil(h.model.startDate)
        h.model.undo()
        XCTAssertEqual(h.model.startDate, first.path.creationDate)
        await eventually(h.timer.deadlines.count == 2)
        XCTAssertEqual(h.timer.deadlines.last, first.path.creationDate.addingTimeInterval(60))

        h.timer.fire()
        await h.model.waitForTimer()
        let r = try XCTUnwrap(h.model.result)
        XCTAssertEqual(r.correctWords, 2)
        XCTAssertEqual(r.duration, 60)
    }

    // MARK: Performance

    func testEvaluatePathPerformance() async {
        let passage = BundledPassages.all.max { $0.words.count < $1.words.count }!
        let h = RoundHarness(passage: passage)
        let words = passage.words
        var batch: [(line: Int, slot: Int, text: String)] = []
        for (i, word) in words.dropLast().enumerated() { batch.append((i / 6, i % 6, word)) }
        h.write(batch)
        await h.model.waitForAnalysis()
        XCTAssertEqual(h.model.match.cursorWordIndex, words.count - 2)

        let rounds = 200
        let clock = ContinuousClock()
        let evaluate = clock.measure { for _ in 0..<rounds { h.model.evaluate() } }
        var editTotal = Duration.zero
        var strokes: [PKStroke] = []
        for i in 0..<20 {
            let s = h.stroke(line: 9, slot: i % 6)
            h.recognizer.text[s.id] = "x"
            strokes.append(s)
            let drawing = h.model.canvas.drawing.appending(PKDrawing(strokes: [s]))
            editTotal += clock.measure { h.model.canvas.drawingChanged(drawing) }
        }
        await h.model.waitForAnalysis()
        let evalMs = Double(evaluate.components.attoseconds) / 1e15 / Double(rounds)
            + Double(evaluate.components.seconds) * 1000 / Double(rounds)
        let editMs = (Double(editTotal.components.attoseconds) / 1e15 + Double(editTotal.components.seconds) * 1000) / 20
        print("ROUND_PERF words=\(words.count) strokes=\(h.model.canvas.drawing.strokes.count) evaluate_avg_ms=\(String(format: "%.3f", evalMs)) edit_to_evaluate_avg_ms=\(String(format: "%.3f", editMs))")
        XCTAssertLessThan(evalMs, 50)
    }
}

