import SwiftUI

/// Popover content for the toolbar gear.
struct RoundSettingsMenu: View {
    @Binding var settings: SinglePlayerSettings
    var linesApplyNextTest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Mode")
                Picker("Mode", selection: $settings.mode) {
                    ForEach(TestMode.choices, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                note("Changing it starts the test over")
            }

            VStack(alignment: .leading, spacing: 4) {
                Stepper(value: $settings.visibleLines, in: SinglePlayerSettings.visibleLineRange) {
                    HStack {
                        Text("Lines visible")
                        Spacer()
                        Text("\(settings.visibleLines)").monospacedDigit().foregroundStyle(Theme.accent)
                    }
                }
                if linesApplyNextTest { note("Applies next test") }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Word coloring")
                Picker("Word coloring", selection: $settings.coloring) {
                    ForEach(WordColoringMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            toggle("Vision leniency", $settings.visionLeniency,
                   "Accept a misread word if Vision OCR's top 3 readings include it")
            toggle("Live stats", $settings.showLiveStats, nil)
            toggle("Finger writing", $settings.fingerWriting,
                   "One finger writes. Scroll with two fingers")
            toggle("Back to pen after erasing", $settings.autoSwitchToPen,
                   "Switches to the pen when you lift after erasing")
            toggle("Debug info", $settings.showDebugInfo,
                   "Shows what the recognizer read and the line of the latest stroke")
        }
        .padding(20)
        .frame(width: 340)
        .tint(Theme.accent)
    }

    private func toggle(_ title: String, _ value: Binding<Bool>, _ footnote: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: value)
            if let footnote { note(footnote) }
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.footnote).foregroundStyle(Theme.secondary)
    }
}
