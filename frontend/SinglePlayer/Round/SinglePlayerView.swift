import SwiftUI
import UIKit

/// The single-player round: the passage (three lines, centered on the
/// furthest progress), live stats, the ruled paper, a floating glass
/// toolbar, and the results card when the test is done.
struct SinglePlayerView: View {
    @StateObject private var model: RoundModel
    private let requestsLandscape: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {
        self.init(model: RoundModel())
    }

    /// `requestsLandscape: false` keeps the window's orientation (tests,
    /// previews).
    init(model: @autoclosure @escaping () -> RoundModel, requestsLandscape: Bool = true) {
        _model = StateObject(wrappedValue: model())
        self.requestsLandscape = requestsLandscape
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                paper
            }
            // Behind the results card the round blurs out, so the card's
            // numbers never sit on top of handwriting, and VoiceOver stays
            // on the card.
            .blur(radius: model.result == nil ? 0 : 14)
            .accessibilityHidden(model.result != nil)

            if let result = model.result {
                resultsOverlay(result)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if requestsLandscape { OrientationRequest.landscape() } }
        .onDisappear { if requestsLandscape { OrientationRequest.all() } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            backButton
            VStack(alignment: .leading, spacing: 18) {
                PassageDisplayView(words: model.words, breaks: model.passageStarts, match: model.match,
                                   source: model.cursorPassage.source)
                if model.settings.showLiveStats {
                    RoundStats(model: model)
                }
                if model.settings.showDebugInfo {
                    Text(model.debugSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Balances the back button so the passage block sits centered.
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Back")
    }

    // MARK: Paper

    private var paper: some View {
        GeometryReader { geo in
            PaperCanvas(model: model.canvas)
                .onAppear { model.paperSizeChanged(geo.size) }
                .onChange(of: geo.size) { _, size in model.paperSizeChanged(size) }
        }
        // Paper behind the canvas too, for overscroll past the ruled area.
        .background(Color(uiColor: PaperCanvas.paperColor))
        .clipShape(.rect(cornerRadius: 22))
        .overlay(alignment: .bottom) {
            if model.result == nil {
                RoundToolbarHost(model: model, canvas: model.canvas)
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .ignoresSafeArea(.keyboard)
    }

    // MARK: Results

    private func resultsOverlay(_ result: TestResult) -> some View {
        ZStack {
            Theme.background.opacity(0.8)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            ResultsCard(result: result,
                        onRestart: { withAnimation(.smooth) { model.restart() } },
                        onNewPassage: { withAnimation(.smooth) { model.newPassage() } })
                .padding(32)
                .accessibilityAddTraits(.isModal)
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
    }
}

/// Elapsed time (time left in timed mode), progress and live WPM, ticking
/// while the test runs.
private struct RoundStats: View {
    @ObservedObject var model: RoundModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: model.startDate == nil || model.isFinished)) { context in
            let elapsed = model.elapsed(at: context.date)
            let wpm = model.liveWPM(elapsed: elapsed)
            if let limit = model.timeLimit {
                LiveStatsBar(time: limit - elapsed, countsDown: true, wordsDone: model.wordsDone, wpm: wpm)
            } else {
                LiveStatsBar(time: elapsed, wordsDone: model.wordsDone,
                             totalWords: model.match.words.count, wpm: wpm)
            }
        }
    }
}

/// The toolbar, observing the canvas for the tool and undo/redo state.
private struct RoundToolbarHost: View {
    @ObservedObject var model: RoundModel
    @ObservedObject var canvas: InkCanvasModel

    var body: some View {
        RoundToolbar(
            tool: Binding(get: { canvas.tool == .pen ? .pen : .eraser },
                          set: { canvas.tool = $0 == .pen ? .pen : .eraser }),
            canUndo: canvas.canUndo, canRedo: canvas.canRedo,
            onUndo: model.undo, onRedo: model.redo,
            onReset: model.reset, onNewPassage: model.newPassage
        ) {
            RoundSettingsMenu(settings: $model.settings, linesApplyNextTest: model.linesApplyNextTest)
        }
    }
}

/// Asks the window scene for landscape while the round is shown. On iPad
/// windows that can be resized freely the system may decline; the layout
/// works in any size.
@MainActor
enum OrientationRequest {
    static func landscape() { request(.landscape) }
    static func all() { request(.all) }

    private static func request(_ mask: UIInterfaceOrientationMask) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

#if DEBUG
#Preview("Round", traits: .landscapeLeft) {
    NavigationStack {
        SinglePlayerView(model: RoundModel(defaults: nil), requestsLandscape: false)
    }
    .preferredColorScheme(.dark)
    .tint(Theme.accent)
}
#endif
