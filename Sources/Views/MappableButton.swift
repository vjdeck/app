import SwiftUI

/// A button that supports input mapping mode.
/// In normal mode: executes action. In mapping mode: selects for MIDI/OSC/keyboard assignment.
struct MappableButton<Label: View>: View {
    let action: MIDIAction
    @ObservedObject var midi: MIDIViewModel
    let isActive: Bool
    let activeBorderColor: Color
    let perform: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    init(
        action: MIDIAction,
        midi: MIDIViewModel,
        isActive: Bool = false,
        activeBorderColor: Color = .cyan,
        perform: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.action = action
        self.midi = midi
        self.isActive = isActive
        self.activeBorderColor = activeBorderColor
        self.perform = perform
        self.label = label
    }

    private var isMappingMode: Bool { midi.isMappingMode }
    private var isPending: Bool { midi.pendingAction == action }
    private var hasMapping: Bool { midi.store.hasMapping(for: action) }

    var body: some View {
        Button {
            if isMappingMode {
                midi.selectActionForMapping(action)
            } else {
                perform()
            }
        } label: {
            label()
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 24, minHeight: 26)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(borderColor, lineWidth: isPending ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { h in isHovering = h }
        .help(helpText)
    }

    private var backgroundColor: Color {
        if isPending {
            return Color.orange.opacity(0.3)
        }
        if isMappingMode && hasMapping {
            return Color.green.opacity(isHovering ? 0.25 : 0.12)
        }
        if isMappingMode {
            return Color.orange.opacity(isHovering ? 0.15 : 0.08)
        }
        if isActive {
            return Color.black.opacity(isHovering ? 0.82 : 0.72)
        }
        return isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.06)
    }

    private var borderColor: Color {
        if isPending { return .orange }
        if isMappingMode && hasMapping { return .green.opacity(0.6) }
        if isMappingMode { return .orange.opacity(0.4) }
        if isActive { return activeBorderColor.opacity(isHovering ? 0.95 : 0.75) }
        return .white.opacity(0.08)
    }

    private var helpText: String {
        if isPending { return "Press a MIDI button, OSC control, or keyboard key to assign..." }
        if isMappingMode { return "Click to assign MIDI/OSC/Key → \(action.rawValue)" }
        if let displayString = midi.store.displayString(for: action) {
            return "\(action.rawValue) — \(displayString)"
        }
        return action.rawValue
    }
}
