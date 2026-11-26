import SwiftUI

struct MasterOutputView: View {
    @ObservedObject var viewModel: MasterOutputViewModel
    let renderer: MasterMixerRenderer
    let syphonService: SyphonOutputService
    @ObservedObject var midi: MIDIViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Top bar — blend mode + MIDI
            HStack(spacing: 8) {
                Menu {
                    ForEach(MasterBlendMode.allCases) { mode in
                        Button {
                            viewModel.blendMode = mode
                        } label: {
                            if viewModel.blendMode == mode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(viewModel.blendMode.label)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.white.opacity(0.75))
                    .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)
                .frame(minWidth: 124, alignment: .leading)

                Spacer()

                // Fullscreen output
                Menu {
                    if viewModel.isFullscreen {
                        Button("Exit Fullscreen") {
                            MasterOutputWindowController.shared.exitFullscreen()
                        }
                        Divider()
                    }
                    ForEach(Array(viewModel.availableScreens.enumerated()), id: \.offset) { idx, screen in
                        let name = screen.localizedName
                        let isCurrent = viewModel.fullscreenDisplayID == (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                        Button {
                            if isCurrent {
                                MasterOutputWindowController.shared.exitFullscreen()
                            } else {
                                MasterOutputWindowController.shared.goFullscreen(on: screen)
                            }
                        } label: {
                            if isCurrent {
                                Text("\(name) ✓")
                            } else {
                                Text(name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: viewModel.isFullscreen ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                        .font(.system(size: 11))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(viewModel.isFullscreen ? Color.cyan.opacity(0.3) : Color.white.opacity(0.08))
                        .foregroundColor(viewModel.isFullscreen ? .cyan : .white.opacity(0.45))
                        .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)

                DarkButton(
                    icon: "link",
                    isActive: midi.isMappingMode,
                    activeColor: .orange
                ) {
                    midi.toggleMappingMode()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.black.opacity(0.85))

            // Video + fader side by side
            HStack(spacing: 0) {
                MasterPreviewView(
                    viewModel: viewModel,
                    renderer: renderer,
                    syphonService: syphonService
                )
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

                // Master opacity fader + toggle — matches video height
                VStack(spacing: 6) {
                    MappableFader(action: .masterOpacity, midi: midi) {
                        VerticalFaderView(
                            value: $viewModel.masterOpacity,
                            onEditingChanged: {
                                midi.setLocalEditing(.masterOpacity, isEditing: $0)
                            }
                        )
                    }

                    MappableButton(action: .masterToggle, midi: midi, perform: {
                        viewModel.masterOpacity = viewModel.masterOpacity > 0 ? 0 : 1
                    }) {
                        Image(systemName: viewModel.masterOpacity > 0 ? "eye" : "eye.slash")
                            .foregroundColor(viewModel.masterOpacity > 0 ? .white : .white.opacity(0.35))
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }

            // Bottom bar — A/B decks + crossfader
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Text("A")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                    Picker("", selection: Binding(
                        get: { viewModel.deckA ?? 0 },
                        set: { viewModel.setDeckA($0 == 0 ? nil : $0) }
                    )) {
                        Text("None").tag(0)
                        ForEach(viewModel.availableDeckNumbers, id: \.self) { n in
                            Text("Deck \(n)").tag(n)
                        }
                    }
                    .frame(width: 80)
                    .labelsHidden()
                }

                MappableButton(action: .masterCrossfadeA, midi: midi, perform: {
                    viewModel.crossfade = 0
                }) {
                    Text("A").font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.7))
                }

                MappableFader(action: .masterCrossfade, midi: midi) {
                    CrossfaderView(
                        value: $viewModel.crossfade,
                        onEditingChanged: {
                            midi.setLocalEditing(.masterCrossfade, isEditing: $0)
                        }
                    )
                }

                MappableButton(action: .masterCrossfadeB, midi: midi, perform: {
                    viewModel.crossfade = 1
                }) {
                    Text("B").font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.7))
                }

                HStack(spacing: 4) {
                    Picker("", selection: Binding(
                        get: { viewModel.deckB ?? 0 },
                        set: { viewModel.setDeckB($0 == 0 ? nil : $0) }
                    )) {
                        Text("None").tag(0)
                        ForEach(viewModel.availableDeckNumbers, id: \.self) { n in
                            Text("Deck \(n)").tag(n)
                        }
                    }
                    .frame(width: 80)
                    .labelsHidden()
                    Text("B")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black.opacity(0.85))
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}

/// Wrapper that makes a fader control mappable.
/// In mapping mode: click selects for input assignment. In normal mode: passthrough.
struct MappableFader<Content: View>: View {
    let action: MIDIAction
    @ObservedObject var midi: MIDIViewModel
    @ViewBuilder let content: () -> Content

    private var isPending: Bool { midi.pendingAction == action }
    private var hasMapping: Bool { midi.store.hasMapping(for: action) }

    var body: some View {
        content()
            .overlay(
                Group {
                    if midi.isMappingMode {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.001))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(borderColor, lineWidth: isPending ? 2 : 1)
                            )
                            .onTapGesture {
                                midi.selectActionForMapping(action)
                            }
                    }
                }
            )
            .help(helpText)
    }

    private var borderColor: Color {
        if isPending { return .orange }
        if hasMapping { return .green.opacity(0.6) }
        return .orange.opacity(0.4)
    }

    private var helpText: String {
        if isPending { return "Move a MIDI CC or OSC control to assign..." }
        if midi.isMappingMode { return "Click to assign MIDI CC/OSC → \(action.rawValue)" }
        if let displayString = midi.store.displayString(for: action) {
            return "\(action.rawValue) — \(displayString)"
        }
        return action.rawValue
    }
}

/// Vertical master fader — 0 (bottom) to 1 (top), real-time drag.
private struct VerticalFaderView: View {
    @Binding var value: Float
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let trackW: CGFloat = 4
            let knobW: CGFloat = 22
            let knobH: CGFloat = 14
            let usable = max(1, geo.size.height - knobH)
            // value 1 = top, 0 = bottom
            let clampedValue = max(0, min(1, value))
            let y = knobH / 2 + usable * CGFloat(1 - clampedValue)

            ZStack {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: trackW)

                // Knob
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(isDragging ? 0.95 : 0.75))
                    .frame(width: knobW, height: knobH)
                    .position(x: geo.size.width / 2, y: y)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        onEditingChanged(true)
                        let pct = Float(1 - (drag.location.y - knobH / 2) / usable)
                        value = max(0, min(1, pct))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(width: 28)
        .onDisappear { onEditingChanged(false) }
    }
}

/// DJ-style crossfader — no directional tint, real-time drag updates.
private struct CrossfaderView: View {
    @Binding var value: Float
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let trackH: CGFloat = 4
            let knobW: CGFloat = 14
            let knobH: CGFloat = 22
            let usable = max(1, geo.size.width - knobW)
            let clampedValue = max(0, min(1, value))
            let x = knobW / 2 + usable * CGFloat(clampedValue)

            ZStack {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.15))
                    .frame(height: trackH)

                // Center tick
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: trackH + 6)

                // Knob
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(isDragging ? 0.95 : 0.75))
                    .frame(width: knobW, height: knobH)
                    .position(x: x, y: geo.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        onEditingChanged(true)
                        let px = drag.location.x - knobW / 2
                        var pct = Float(px / usable)
                        // Magnetic snap to 0/1 within 3px of edges
                        if px < 3 { pct = 0 }
                        else if px > usable - 3 { pct = 1 }
                        value = max(0, min(1, pct))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 28)
        .onDisappear { onEditingChanged(false) }
    }
}
