import SwiftUI

/// DJ-style CUE button. Plays while held; on release pauses and seeks back
/// to the position captured at press time. In mapping mode, click selects
/// the action for MIDI/OSC/keyboard assignment instead of triggering press/hold.
struct CueButton: View {
    @ObservedObject var midi: MIDIViewModel
    let isActive: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    private let action: MIDIAction = .cue
    private var isMappingMode: Bool { midi.isMappingMode }
    private var isPending: Bool { midi.pendingAction == action }
    private var hasMapping: Bool { midi.store.hasMapping(for: action) }
    private var highlight: Bool { isPressed || isActive }

    var body: some View {
        Text("CUE")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(foregroundColor)
            .frame(width: 36, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(borderColor, lineWidth: isPending ? 2 : 1)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(pressGesture)
            .help(helpText)
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !isPressed {
                    isPressed = true
                    if isMappingMode {
                        midi.selectActionForMapping(action)
                    } else {
                        onPress()
                    }
                }
            }
            .onEnded { _ in
                guard isPressed else { return }
                isPressed = false
                if !isMappingMode {
                    onRelease()
                }
            }
    }

    private var foregroundColor: Color {
        if isMappingMode { return .white.opacity(0.85) }
        return highlight ? .orange : .white.opacity(0.85)
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
        return isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.06)
    }

    private var borderColor: Color {
        if isPending { return .orange }
        if isMappingMode && hasMapping { return .green.opacity(0.6) }
        if isMappingMode { return .orange.opacity(0.4) }
        return highlight ? Color.orange.opacity(0.6) : Color.white.opacity(0.08)
    }

    private var helpText: String {
        if isPending { return "Press a MIDI button, OSC control, or keyboard key to assign..." }
        if isMappingMode { return "Click to assign MIDI/OSC/Key → \(action.rawValue)" }
        if let displayString = midi.store.displayString(for: action) {
            return "CUE — \(displayString)"
        }
        return "CUE — hold to preview, release to return to start position"
    }
}
