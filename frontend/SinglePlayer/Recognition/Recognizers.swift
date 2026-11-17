import PencilKit
import Vision

// MARK: - Vision values

struct VisionCandidate: Equatable, Sendable {
    let string: String
    /// Vision's normalized confidence, 0–1. Not a calibrated probability.
    let confidence: Float
}

struct VisionRegion: Equatable, Sendable {
    /// Normalized to the ink image; origin bottom-left.
    let bounds: CGRect
    /// Ranked best first.
    let candidates: [VisionCandidate]
}

/// How Vision OCR reads a rendered ink image (only used for Vision leniency).
struct VisionSettings: Equatable, Sendable {
    var accurate = true
    /// Off by default: language correction rewrites misspellings into real
    /// words, which would hide the writer's mistakes.
    var languageCorrection = false
    /// Top-N ranked candidates kept per region; clamped to Vision's 1...10.
    var candidateCount = 3
    /// Extra vocabulary (for example the passage's words). Vision ignores it
    /// while language correction is off.
    var customWords: [String] = []

    var maximumCandidates: Int { min(10, max(1, candidateCount)) }

    func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = languageCorrection
        request.customWords = customWords
        return request
    }
}

// MARK: - Recognizer seams

/// Recognizes text directly from strokes. The production adapter wraps
/// `PKStrokeRecognizer`; tests inject fakes.
@MainActor
protocol StrokeRecognizing {
    var recognizerVersion: String { get }
    /// Starts a fresh recognition session for a snapshot of the drawing.
    func prepare(_ drawing: PKDrawing) async -> any StrokeRecognitionSession
}

@MainActor
protocol StrokeRecognitionSession {
    /// Text of the whole prepared drawing, unchanged (case and punctuation kept).
    func wholeText() async -> String?
    func text(forStroke id: UUID) async -> String?
    /// Text of just these strokes of the prepared drawing, read together.
    func text(forStrokes ids: [UUID]) async -> String?
}

/// Recognizes text in a rendered image. Implementations do the heavy work off
/// the main actor.
@MainActor
protocol TextImageRecognizing {
    func recognize(_ image: CGImage, settings: VisionSettings) async throws -> [VisionRegion]
}

// MARK: - Vision adapter

@MainActor
struct VisionTextRecognizer: TextImageRecognizing {
    nonisolated init() {}

    func recognize(_ image: CGImage, settings: VisionSettings) async throws -> [VisionRegion] {
        try await Task.detached(priority: .utility) {
            let request = settings.makeRequest()
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).map { observation in
                VisionRegion(
                    bounds: observation.boundingBox,
                    candidates: observation.topCandidates(settings.maximumCandidates).map {
                        VisionCandidate(string: $0.string, confidence: $0.confidence)
                    }
                )
            }
        }.value
    }
}
