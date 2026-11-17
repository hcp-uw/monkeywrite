import PencilKit
import UIKit

/// The one rendering of retained ink as an image, for Vision OCR.
///
/// Our paper is dark and our ink light, but Vision reads best (and was tuned
/// in pencilDemo) on black ink over white. So the image is rendered from a
/// copy of the strokes recolored to black, in light appearance (so PencilKit
/// does not adapt the black ink to white), on opaque white paper, cropped to
/// the stroke bounds plus a margin. The retained drawing is never changed.
struct InkImage {
    /// Points of paper kept around the stroke bounds.
    static let margin: CGFloat = 20
    /// Image pixels per canvas point.
    static let scale: CGFloat = 2

    let image: UIImage
    /// The rendered area in canvas points.
    let crop: CGRect
    var scale: CGFloat { Self.scale }

    var cgImage: CGImage? { image.cgImage }
    func pngData() -> Data? { image.pngData() }

    /// The area an image of `drawing` covers, or nil for an empty drawing.
    static func crop(for drawing: PKDrawing) -> CGRect? {
        drawing.strokes.isEmpty ? nil : drawing.bounds.insetBy(dx: -margin, dy: -margin)
    }

    /// The same strokes (paths, masks, transforms) in black ink.
    static func blackInk(_ strokes: [PKStroke]) -> PKDrawing {
        PKDrawing(strokes: strokes.map { stroke in
            var black = stroke
            black.ink = PKInk(stroke.ink.inkType, color: .black)
            return black
        })
    }

    /// Renders all of `drawing`, or returns nil when it has no strokes.
    @MainActor
    init?(_ drawing: PKDrawing) {
        self.init(strokes: drawing.strokes)
    }

    /// Renders only `strokes` (for example one word, for a per-word Vision
    /// crop), or returns nil when there are none.
    @MainActor
    init?(strokes: [PKStroke]) {
        let drawing = Self.blackInk(strokes)
        guard let crop = Self.crop(for: drawing) else { return nil }
        var rendered: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let ink = drawing.image(from: crop, scale: Self.scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = Self.scale
            format.opaque = true
            rendered = UIGraphicsImageRenderer(size: crop.size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: crop.size))
                ink.draw(at: .zero)
            }
        }
        guard let rendered else { return nil }
        self.image = rendered
        self.crop = crop
    }

    /// Renders the strokes of `drawing` whose IDs are in `strokeIDs`.
    @MainActor
    init?(_ drawing: PKDrawing, strokeIDs: [UUID]) {
        let wanted = Set(strokeIDs)
        self.init(strokes: drawing.strokes.filter { wanted.contains($0.id) })
    }
}
