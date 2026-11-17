import SwiftUI
import UIKit

/// Colors for the passage display, tuned for the dark `Theme` background.
enum RoundColors {
    static let correct = Color(red: 0.56, green: 0.80, blue: 0.56)
    static let incorrect = Color(red: 0.94, green: 0.42, blue: 0.40)
    static let pending = Theme.secondary.opacity(0.75)
    static let current = Theme.text
    static let caret = Theme.accent
}

enum RoundFonts {
    static let passageSize: CGFloat = 30
    static let passageUIFont = UIFont.monospacedSystemFont(ofSize: passageSize, weight: .regular)
    static let passage = Font(passageUIFont)
    static let stats = Font.system(.title3, design: .monospaced).weight(.medium)
}

enum RoundTool: String, CaseIterable, Identifiable {
    case pen, eraser
    var id: Self { self }
    var symbol: String { self == .pen ? "pencil.tip" : "eraser" }
    var label: String { self == .pen ? "Pen" : "Stroke eraser" }
}
