import PencilKit
import SwiftUI
import XCTest
@testable import MonkeyWrite

/// Renders the round screen to PNGs (in NSTemporaryDirectory()/RoundShots,
/// path printed as ROUND_SHOT) for a visual check. Asserts only that
/// rendering works.
@MainActor
final class SinglePlayerSnapshotTests: XCTestCase {
    private static let landscape = CGSize(width: 1376, height: 1032)
    private static let portrait = CGSize(width: 1032, height: 1376)

    private var strokeClock = Date().addingTimeInterval(-60)

    /// Strokes 0.9 s apart, so the results card shows a plausible speed.
    private func nextStrokeStart() -> Date {
        strokeClock = strokeClock.addingTimeInterval(0.9)
        return strokeClock
    }

    private var shotsFolder: URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("RoundShots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func host(_ model: RoundModel, size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let root = NavigationStack {
            SinglePlayerView(model: model, requestsLandscape: false)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        return window
    }

    private func settle(_ seconds: Double = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func shoot(_ window: UIWindow, _ name: String) throws {
        window.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = shotsFolder.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("ROUND_SHOT \(url.path)")
    }

    /// Handwriting-ish strokes for `words` on `line`, starting at `x`.
    private func scribble(_ words: [String], line: Int, layout: PaperLayout, recognizer: ScriptedStrokeRecognizer,
                          x start: CGFloat = 40) -> [PKStroke] {
        var x = start
        var strokes: [PKStroke] = []
        let band = layout.band(ofLine: line)
        let lh = layout.lineHeight
        for word in words {
            let letters = max(1, word.count)
            let width = CGFloat(letters) * lh * 0.2
            let base = band.upperBound - lh * 0.22
            let xHeight = lh * 0.32
            let steps = letters * 6
            let points = (0...steps).map { i -> PKStrokePoint in
                let t = CGFloat(i) / CGFloat(steps)
                let phase = t * CGFloat(letters) * .pi * 2
                let y = base - xHeight * (0.5 + 0.5 * sin(phase - .pi / 2)) - (i % 12 == 3 ? xHeight * 0.6 : 0)
                return PKStrokePoint(location: CGPoint(x: x + t * width, y: y), timeOffset: Double(t) * 0.6,
                                     size: CGSize(width: 3.5, height: 3.5), opacity: 1, force: 1,
                                     azimuth: 0, altitude: .pi / 2)
            }
            let stroke = PKStroke(ink: PKInk(.pen, color: UIColor(Theme.text)),
                                  path: PKStrokePath(controlPoints: points, creationDate: nextStrokeStart()))
            recognizer.text[stroke.id] = word
            strokes.append(stroke)
            x += width + lh * 0.6
        }
        return strokes
    }

    /// Writes `lines` of words, pushing the drawing onto the canvas view (an
    /// edit, then undo + redo, which the canvas shows as a replacement).
    private func write(_ lines: [[String]], h model: RoundModel, recognizer: ScriptedStrokeRecognizer) async throws {
        let layout = try XCTUnwrap(model.canvas.layout)
        var strokes: [PKStroke] = []
        for (i, words) in lines.enumerated() {
            strokes += scribble(words, line: i, layout: layout, recognizer: recognizer)
        }
        model.canvas.drawingChanged(PKDrawing(strokes: strokes))
        model.undo()
        model.redo()
        await model.waitForAnalysis()
    }

    private func makeModel(_ recognizer: ScriptedStrokeRecognizer) -> RoundModel {
        RoundModel(strokeRecognizer: recognizer, textRecognizer: FakeTextImageRecognizer(),
                   passageSource: BundledPassages(defaults: temporaryDefaults()), passage: BundledPassages.all[0], defaults: nil)
    }

    func testRenderRoundScreens() async throws {
        let recognizer = ScriptedStrokeRecognizer()
        let model = makeModel(recognizer)
        let window = try host(model, size: Self.landscape)
        await settle()
        try shoot(window, "round-landscape-empty")
        XCTAssertNotNil(model.canvas.layout, "The paper laid out")

        let words = model.passage.words
        try await write([Array(words[0..<5]), ["you", "do", "nat", "observe."], Array(words[9..<12])],
                        h: model, recognizer: recognizer)
        await settle()
        try shoot(window, "round-landscape-midround")
        XCTAssertGreaterThan(model.match.cursorWordIndex, 5)

        let portraitModel = makeModel(ScriptedStrokeRecognizer())
        let portraitWindow = try host(portraitModel, size: Self.portrait)
        await settle()
        try shoot(portraitWindow, "round-portrait-empty")
        portraitWindow.isHidden = true
        window.isHidden = true
    }

    func testRenderResultsCard() async throws {
        let recognizer = ScriptedStrokeRecognizer()
        let passage = BundledPassages.all[3]
        let model = RoundModel(strokeRecognizer: recognizer, textRecognizer: FakeTextImageRecognizer(),
                               passageSource: BundledPassages(defaults: temporaryDefaults()), passage: passage, defaults: nil)
        model.settings.mode = .passage
        let window = try host(model, size: Self.landscape)
        await settle()
        let words = passage.words
        try await write(stride(from: 0, to: words.count, by: 5).map { Array(words[$0..<min($0 + 5, words.count)]) },
                        h: model, recognizer: recognizer)
        XCTAssertNotNil(model.result)
        XCTAssertEqual(model.result?.missedWords, 0)
        XCTAssertEqual(model.result?.accuracy, 1, "Lines recognized out of order record no false first attempts")
        await settle(0.8)
        try shoot(window, "round-landscape-results")
        window.isHidden = true
    }
}

