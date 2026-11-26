import SwiftUI

struct VideoOverlayView: View {
    @ObservedObject var playerViewModel: PlayerViewModel
    let videoW: CGFloat
    let videoH: CGFloat
    @ObservedObject var midi: MIDIViewModel

    @State private var isHovering = false
    @State private var isAudioOutputButtonHovering = false
    @State private var isAudioOutputPopoverPresented = false

    private var hasCustomAudioOutput: Bool {
        playerViewModel.deckAudioOutput != .appDefault
    }

    private var shouldShowAudioControls: Bool {
        !playerViewModel.isStillImage
            && (isHovering || midi.isMappingMode || playerViewModel.isMuted || hasCustomAudioOutput || isAudioOutputPopoverPresented)
    }

    private var shouldShowAudioOutputButton: Bool {
        !playerViewModel.isStillImage
            && (isHovering || midi.isMappingMode || hasCustomAudioOutput || isAudioOutputPopoverPresented)
    }

    var body: some View {
        ZStack {
            VideoPreviewView(renderer: playerViewModel.renderer, playerViewModel: playerViewModel)

            // Top-left: instance number, Top-right: rate
            VStack {
                HStack(alignment: .top) {
                    Text("\(playerViewModel.syphonInstanceNumber)")
                        .font(.system(size: max(videoH * 0.1, 14), weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black, radius: 2, x: 0, y: 1)
                        .shadow(color: .black, radius: 6)
                        .shadow(color: .black, radius: 12)

                    Spacer()

                    #if DEBUG
                    if XcodeDebugMode.isEnabled, !playerViewModel.debugFrameSourceText.isEmpty {
                        Text(playerViewModel.debugFrameSourceText)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.65))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.cyan.opacity(0.75), lineWidth: 1)
                            )
                            .cornerRadius(3)
                    }
                    #endif

                    if playerViewModel.isVideoLoaded,
                       !playerViewModel.isStillImage,
                       abs(playerViewModel.currentRate - 1.0) > 0.0001 {
                        Text(String(format: "x%.2f", playerViewModel.currentRate))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.orange.opacity(0.8), lineWidth: 1)
                            )
                            .cornerRadius(4)
                    }

                    AudioProcessingBadge(state: playerViewModel.audioProcessing)
                }
                Spacer()
            }
            .padding(6)

            // Volume fader + mute - right edge
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if !playerViewModel.isStillImage && (isHovering || midi.isMappingMode) {
                        MappableFader(action: .volume, midi: midi) {
                            VolumeFader(
                                volume: $playerViewModel.volume,
                                height: min(videoH * 0.55, 100),
                                onEditingChanged: {
                                    midi.setLocalEditing(.volume, isEditing: $0)
                                }
                            )
                        }
                        .transition(.opacity)
                    }

                    if shouldShowAudioControls {
                        HStack(spacing: 2) {
                            if shouldShowAudioOutputButton {
                                Button {
                                    isAudioOutputPopoverPresented.toggle()
                                } label: {
                                    AudioOutputButtonLabel(
                                        isCustomOutput: hasCustomAudioOutput,
                                        isHovering: isAudioOutputButtonHovering || isAudioOutputPopoverPresented
                                    )
                                }
                                .buttonStyle(.plain)
                                .popover(isPresented: $isAudioOutputPopoverPresented, arrowEdge: .trailing) {
                                    AudioOutputPopover(selection: $playerViewModel.deckAudioOutput) {
                                        isAudioOutputPopoverPresented = false
                                    }
                                }
                                .fixedSize()
                                .onHover { isAudioOutputButtonHovering = $0 }
                            }

                            MappableButton(
                                action: .muteToggle,
                                midi: midi,
                                isActive: playerViewModel.isMuted,
                                activeBorderColor: .white
                            ) {
                                playerViewModel.isMuted.toggle()
                            } label: {
                                Image(systemName: playerViewModel.isMuted ? "speaker.slash.fill" : "speaker.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(playerViewModel.isMuted ? .red.opacity(0.95) : .white.opacity(0.85))
                                    .frame(width: 18, height: 14)
                                    .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1)
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .frame(width: videoW, height: videoH)
        .background(Color.black)
        .cornerRadius(4)
        .onHover { hovering in
            if !hovering {
                isAudioOutputButtonHovering = false
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

private struct AudioOutputButtonLabel: View {
    let isCustomOutput: Bool
    let isHovering: Bool

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: isCustomOutput ? "hifispeaker.fill" : "hifispeaker")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isCustomOutput ? .blue.opacity(0.95) : .white.opacity(0.85))
                .frame(width: 18, height: 14)
                .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1)

            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(isCustomOutput ? .blue.opacity(0.9) : .white.opacity(0.8))
                .frame(width: 7, height: 14)
                .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 1)
        }
        .frame(minWidth: 24, minHeight: 26)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var backgroundColor: Color {
        if isCustomOutput {
            return Color.black.opacity(isHovering ? 0.82 : 0.72)
        }
        return isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.06)
    }

    private var borderColor: Color {
        if isCustomOutput {
            return Color.white.opacity(isHovering ? 0.95 : 0.75)
        }
        return Color.white.opacity(0.08)
    }
}

private struct AudioOutputPopover: View {
    @Binding var selection: DeckAudioOutput
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                audioOutputRow("App Default", output: .appDefault)
                audioOutputRow("System Default", output: .systemDefault)

                Divider()
                    .padding(.vertical, 2)

                ForEach(PCMAudioEngine.listOutputDevices()) { device in
                    audioOutputRow(device.name, output: .device(device.id))
                }
            }
            .padding(6)
        }
        .frame(minWidth: 190, maxHeight: 260, alignment: .topLeading)
    }

    private func audioOutputRow(_ title: String, output: DeckAudioOutput) -> some View {
        Button {
            selection = output
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                    .opacity(selection == output ? 1 : 0)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 12)
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Vertical Volume Fader

struct VolumeFader: View {
    @Binding var volume: Float
    let height: CGFloat
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isHoveringFader = false

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let fillH = h * CGFloat(volume)

            // Track background with dark backing for visibility
            let trackRect = CGRect(x: 2, y: 0, width: w - 4, height: h)
            context.fill(Path(roundedRect: trackRect, cornerRadius: 3), with: .color(.black.opacity(0.5)))
            context.stroke(Path(roundedRect: trackRect, cornerRadius: 3), with: .color(.white.opacity(0.15)), lineWidth: 1)

            // Fill from bottom
            let fillRect = CGRect(x: 2, y: h - fillH, width: w - 4, height: fillH)
            context.fill(Path(roundedRect: fillRect, cornerRadius: 3), with: .color(.cyan.opacity(0.4)))

            // Knob bar
            let knobY = h - fillH
            let clampedKnobY = max(1, min(h - 5, knobY))
            let knobRect = CGRect(x: 1, y: clampedKnobY, width: w - 2, height: 4)
            context.fill(Path(roundedRect: knobRect, cornerRadius: 2), with: .color(isHoveringFader ? .cyan : .white.opacity(0.8)))
        }
        .frame(width: 18, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onEditingChanged(true)
                    let normalized = 1.0 - Float(value.location.y / height)
                    volume = max(0, min(1, normalized))
                }
                .onEnded { _ in
                    onEditingChanged(false)
                }
        )
        .onHover { h in isHoveringFader = h }
        .onDisappear { onEditingChanged(false) }
    }
}

// MARK: - Audio Processing Badge

private struct AudioProcessingBadge: View {
    let state: AudioProcessingState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .processing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Loading")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.6))
            .cornerRadius(4)
            .transition(.opacity)
        case .ready:
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                Text("Ready")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundColor(.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.green.opacity(0.5), lineWidth: 1)
            )
            .cornerRadius(4)
            .transition(.opacity)
        }
    }
}
