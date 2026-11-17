import PencilKit

/// Splits one line's strokes into words by the horizontal gaps between them.
/// Pure and deterministic.
enum WordGrouper {
    /// A gap wider than this (times the line height) between a stroke and the
    /// word so far starts a new word. Letter gaps in cursive and print are
    /// usually well under half an x-height; word gaps are usually wider.
    static let gapFraction: CGFloat = 0.45

    /// One horizontal extent per stroke, in drawing order.
    struct Extent: Equatable, Sendable {
        let id: UUID
        let minX: CGFloat
        let maxX: CGFloat
    }

    /// Word groups left to right; each group's IDs in drawing order.
    static func group(_ strokes: [PKStroke], lineHeight: CGFloat) -> [[UUID]] {
        group(strokes.map(StrokeGeometry.init), lineHeight: lineHeight)
    }

    static func group(_ strokes: [StrokeGeometry], lineHeight: CGFloat) -> [[UUID]] {
        group(extents: strokes.filter { !$0.points.isEmpty }
            .map { Extent(id: $0.id, minX: $0.bounds.minX, maxX: $0.bounds.maxX) },
              lineHeight: lineHeight)
    }

    /// Sorts by minX and merges a stroke into the current cluster when its
    /// minX is at most `cluster.maxX + gapFraction * lineHeight`.
    static func group(extents: [Extent], lineHeight: CGFloat) -> [[UUID]] {
        let threshold = gapFraction * lineHeight
        let order = Dictionary(uniqueKeysWithValues: extents.enumerated().map { ($1.id, $0) })
        let sorted = extents.enumerated().sorted {
            ($0.element.minX, $0.offset) < ($1.element.minX, $1.offset)
        }.map(\.element)
        var clusters: [(maxX: CGFloat, ids: [UUID])] = []
        for extent in sorted {
            if let last = clusters.last, extent.minX <= last.maxX + threshold {
                clusters[clusters.count - 1].maxX = max(last.maxX, extent.maxX)
                clusters[clusters.count - 1].ids.append(extent.id)
            } else {
                clusters.append((extent.maxX, [extent.id]))
            }
        }
        return clusters.map { cluster in cluster.ids.sorted { order[$0, default: 0] < order[$1, default: 0] } }
    }
}
