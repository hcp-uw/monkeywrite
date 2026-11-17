import SwiftUI

/// Floating Liquid Glass capsule with pen/eraser, undo/redo, reset, new passage
/// and a settings popover. Pure: all state and actions are passed in.
struct RoundToolbar<SettingsContent: View>: View {
    @Binding var tool: RoundTool
    var canUndo: Bool
    var canRedo: Bool
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onReset: () -> Void
    var onNewPassage: () -> Void
    @ViewBuilder var settings: () -> SettingsContent

    @State private var showSettings = false
    @Namespace private var glassNS

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(RoundTool.allCases) { t in
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { tool = t }
                    } label: {
                        icon(t.symbol)
                            .foregroundStyle(tool == t ? Theme.accent : Theme.text)
                            .background {
                                if tool == t {
                                    Color.clear
                                        .glassEffect(.regular.tint(Theme.accent.opacity(0.25)), in: .circle)
                                        .glassEffectID("selection", in: glassNS)
                                }
                            }
                    }
                    .accessibilityLabel(t.label)
                    .accessibilityAddTraits(tool == t ? .isSelected : [])
                }
                divider
                action("arrow.uturn.backward", "Undo", enabled: canUndo, onUndo)
                action("arrow.uturn.forward", "Redo", enabled: canRedo, onRedo)
                action("arrow.counterclockwise", "Reset", enabled: true, onReset)
                divider
                action("shuffle", "New passage", enabled: true, onNewPassage)
                Button { showSettings = true } label: { icon("gearshape").foregroundStyle(Theme.text) }
                    .accessibilityLabel("Settings")
                    .popover(isPresented: $showSettings) {
                        settings().presentationCompactAdaptation(.popover)
                    }
            }
            .buttonStyle(.plain)
            .padding(6)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private var divider: some View {
        Capsule().fill(Theme.secondary.opacity(0.3)).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 19, weight: .medium))
            .frame(width: 48, height: 48)
            .contentShape(Circle())
    }

    private func action(_ symbol: String, _ label: String, enabled: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { icon(symbol).foregroundStyle(Theme.text) }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
            .accessibilityLabel(label)
    }
}
