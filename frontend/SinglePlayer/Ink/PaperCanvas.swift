import PencilKit
import SwiftUI

/// The ruled, dark, vertically scrolling notebook page, driven by an
/// `InkCanvasModel`.
///
/// Appearance: PencilKit adapts ink for dark appearance (dark ink drawn light
/// and the other way round). Our ink color is already the light color we want
/// on dark paper, so the canvas is pinned to light appearance: PencilKit then
/// draws the stored color unchanged, and the paper color is set explicitly.
struct PaperCanvas: UIViewRepresentable {
    @ObservedObject var model: InkCanvasModel

    static var paperColor: UIColor { UIColor(Theme.surface) }
    static var ruleColor: UIColor { UIColor(Theme.secondary).withAlphaComponent(0.15) }

    /// PencilKit's built-in undo (such as the three-finger swipe) would keep a
    /// second history that diverges from the model's. Registrations on this
    /// canvas's undo manager are ignored, so the model's history is the only one.
    final class CanvasView: PKCanvasView {
        private let ignoredUndoManager: UndoManager = {
            let manager = UndoManager()
            manager.disableUndoRegistration()
            return manager
        }()
        override var undoManager: UndoManager? { ignoredUndoManager }

        /// The document `replacement` this canvas shows; nil before the first.
        var shownReplacement: Int?
        /// The rules, a subview behind the ink so they scroll with the content.
        let rules = RuledPaperView()
        /// The paper to show; nil until the model has a layout.
        var paper: (layout: PaperLayout, lineCount: Int)? {
            didSet { applyPaperGeometry() }
        }
        /// Reports every laid-out size.
        var onLayout: ((CGSize) -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            if subviews.first !== rules { sendSubviewToBack(rules) }
            applyPaperGeometry()
            onLayout?(bounds.size)
        }

        /// Width = view width (no horizontal scrolling); height = the paper's
        /// lines. Only changes the content size, never the offset, so the
        /// paper never scrolls by itself.
        func applyPaperGeometry() {
            let width = bounds.width
            let height = paper.map { $0.layout.contentHeight(lineCount: $0.lineCount) } ?? bounds.height
            let size = CGSize(width: width, height: height)
            if contentSize != size { contentSize = size }
            let rulesFrame = CGRect(origin: .zero, size: size)
            if rules.frame != rulesFrame { rules.frame = rulesFrame }
            rules.configure(layout: paper?.layout, lineCount: paper?.lineCount ?? 0)
        }
    }

    func makeUIView(context: Context) -> CanvasView {
        let canvas = CanvasView()
        // See the type comment: keep PencilKit from adapting our light ink.
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        // PencilKit paints an opaque background color over its subviews, so
        // the canvas is clear and the ruled underlay paints the paper.
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = true
        canvas.alwaysBounceVertical = true
        canvas.alwaysBounceHorizontal = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.insertSubview(canvas.rules, at: 0)
        let coordinator = context.coordinator
        canvas.onLayout = { [weak coordinator] size in coordinator?.canvasDidLayout(size) }
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        canvas.addInteraction(pencilInteraction)
        // A new PKCanvasView starts with PencilKit's black pen, which
        // `CanvasTool.matches` would accept as our pen, so set ours here.
        canvas.tool = model.tool.tool
        updateCanvas(canvas)
        return canvas
    }

    func updateUIView(_ canvas: CanvasView, context: Context) {
        updateCanvas(canvas)
    }

    func updateCanvas(_ canvas: CanvasView) {
        let input = model.inputPolicy
        if canvas.drawingPolicy != input.drawingPolicy { canvas.drawingPolicy = input.drawingPolicy }
        if canvas.panGestureRecognizer.minimumNumberOfTouches != input.scrollTouches {
            canvas.panGestureRecognizer.minimumNumberOfTouches = input.scrollTouches
        }
        if canvas.drawingGestureRecognizer.isEnabled != model.isWritingEnabled {
            canvas.drawingGestureRecognizer.isEnabled = model.isWritingEnabled
        }
        // Only reassign on a real change so an in-progress stroke is not interrupted.
        if !model.tool.matches(canvas.tool) {
            canvas.tool = model.tool.tool
        }
        // Push the drawing only when the app replaced it (undo, redo, clear,
        // reset). User edits came from this canvas; writing back a drawing that
        // merely differs (for example one a mid-gesture callback has not
        // reported yet) would hand PencilKit an older version to merge with.
        if canvas.shownReplacement != model.document.replacement {
            canvas.shownReplacement = model.document.replacement
            canvas.drawing = model.drawing
        }
        let paper = model.layout.map { (layout: $0, lineCount: model.lineCount) }
        if paper?.layout != canvas.paper?.layout || paper?.lineCount != canvas.paper?.lineCount {
            canvas.paper = paper
        }
    }

    /// A late callback from a discarded canvas, such as delayed Pencil
    /// pressure, must not report its stale drawing as a new edit.
    static func dismantleUIView(_ canvas: CanvasView, coordinator: Coordinator) {
        canvas.delegate = nil
        canvas.onLayout = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIPencilInteractionDelegate {
        let model: InkCanvasModel
        private var reportedSize: CGSize?

        init(model: InkCanvasModel) { self.model = model }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Assigning the model's drawing (for example on Clear) can also
            // trigger this delegate. Do not count that as another user edit.
            guard !model.document.isCurrent(canvasView.drawing) else { return }
            model.drawingChanged(canvasView.drawing)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            model.toolUseBegan()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            // Take in the gesture's last change first, in case PencilKit
            // reports it after the end of the tool use.
            canvasViewDrawingDidChange(canvasView)
            model.toolUseEnded()
        }

        /// Layout can run inside a SwiftUI update, where publishing is not
        /// allowed, so the size reaches the model on the next main-queue turn.
        func canvasDidLayout(_ size: CGSize) {
            guard size != reportedSize, size.height > 0 else { return }
            reportedSize = size
            let model = model
            DispatchQueue.main.async { model.viewportDidChange(size) }
        }

        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            // Honor the user's double-tap preference from iPad Settings.
            switch UIPencilInteraction.preferredTapAction {
            case .switchEraser, .switchPrevious: model.toggleEraser()
            default: break
            }
        }
    }
}

/// Faint horizontal rules at the bottom of every paper line.
final class RuledPaperView: UIView {
    private let shape = CAShapeLayer()
    private var drawn: (layout: PaperLayout?, lineCount: Int, width: CGFloat)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = PaperCanvas.paperColor
        shape.fillColor = nil
        shape.lineWidth = 1
        shape.strokeColor = PaperCanvas.ruleColor.cgColor
        layer.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(layout: PaperLayout?, lineCount: Int) {
        let width = bounds.width
        if let drawn, drawn.layout == layout, drawn.lineCount == lineCount, drawn.width == width { return }
        drawn = (layout, lineCount, width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        let path = UIBezierPath()
        if let layout {
            for line in 0..<lineCount {
                // Half-point offset keeps a 1-point rule crisp at @2x.
                let y = layout.ruleY(forLine: line).rounded() + 0.5
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
        }
        shape.path = path.cgPath
        CATransaction.commit()
    }
}
