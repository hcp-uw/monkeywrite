import PencilKit

/// The only code in the app that touches `PKStrokeRecognizer` (iPadOS 27).
@MainActor
struct PencilKitStrokeRecognizer: StrokeRecognizing {
    nonisolated init() {}

    var recognizerVersion: String { "\(PKStrokeRecognizer.recognitionVersion)" }

    func prepare(_ drawing: PKDrawing) async -> any StrokeRecognitionSession {
        // A canceled task may still be inside a PencilKit await. Giving each
        // analysis its own recognizer prevents it from changing newer work.
        let recognizer = PKStrokeRecognizer(preferredLanguages: [Locale.Language(identifier: "en")])
        await recognizer.updateDrawing(drawing)
        return Session(recognizer: recognizer)
    }

    @MainActor
    struct Session: StrokeRecognitionSession {
        let recognizer: PKStrokeRecognizer

        func wholeText() async -> String? {
            await recognizer.recognizedText()
        }

        func text(forStroke id: UUID) async -> String? {
            await recognizer.recognizedText(strokeIDs: [id])
        }

        func text(forStrokes ids: [UUID]) async -> String? {
            await recognizer.recognizedText(strokeIDs: Set(ids))
        }
    }
}
