import SwiftUI

// This folder is the stats teammate's area. Keep it self-contained: it only
// depends on `TestResult` (and the app-wide `Theme`).

/// Minimal Liquid Glass results card.
struct ResultsCard: View {
    let result: TestResult
    var onRestart: () -> Void
    var onNewPassage: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 2) {
                Text(String(Int(result.wpm.rounded())))
                    .font(.system(size: 96, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                Text("wpm").font(.headline).foregroundStyle(Theme.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Int(result.wpm.rounded())) words per minute")

            HStack(spacing: 40) {
                stat("accuracy", "\(Int((result.accuracy * 100).rounded()))%")
                stat("raw", String(Int(result.rawWPM.rounded())))
                stat("time", Self.time(result.duration))
            }

            Text(detail)
                .font(.footnote).foregroundStyle(Theme.secondary)

            HStack(spacing: 14) {
                Button("Restart", systemImage: "arrow.counterclockwise", action: onRestart)
                    .buttonStyle(.glass)
                Button("New passage", systemImage: "shuffle", action: onNewPassage)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
    }

    private var detail: String {
        var parts = ["\(result.wordsCorrected) corrected", "\(result.missedWords) missed"]
        if result.visionLeniencyEnabled { parts.append("\(result.assistedWords) assisted") }
        return parts.joined(separator: "  ·  ")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(.title, design: .monospaced).weight(.medium)).foregroundStyle(Theme.text)
            Text(label).font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    /// m:ss.t
    static func time(_ t: TimeInterval) -> String {
        let tenths = Int((max(0, t) * 10).rounded())
        return "\(tenths / 600):" + String(format: "%02d", (tenths / 10) % 60) + ".\(tenths % 10)"
    }
}
