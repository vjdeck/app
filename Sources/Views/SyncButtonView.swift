import SwiftUI

struct SyncButtonView: View {
    @ObservedObject var syncViewModel: SyncViewModel
    var onSync: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: {
            if syncViewModel.isActive {
                syncViewModel.stopSync()
            } else {
                onSync()
            }
        }) {
            AutoSyncButtonLabel(
                state: syncViewModel.state,
                syncedSystemImage: "checkmark.circle.fill"
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(bgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
    }

    private var bgColor: Color {
        switch syncViewModel.state {
        case .listening: return Color.orange.opacity(isHovering ? 0.3 : 0.2)
        case .synced: return Color.green.opacity(isHovering ? 0.3 : 0.2)
        case .resyncing: return Color.red.opacity(isHovering ? 0.3 : 0.2)
        case .failed: return Color.red.opacity(isHovering ? 0.3 : 0.2)
        default: return Color.white.opacity(isHovering ? 0.12 : 0.06)
        }
    }

    private var borderColor: Color {
        switch syncViewModel.state {
        case .listening: return .orange.opacity(0.5)
        case .synced: return .green.opacity(0.5)
        case .resyncing: return .red.opacity(0.5)
        case .failed: return .red.opacity(0.5)
        default: return .white.opacity(0.08)
        }
    }
}

struct AutoSyncButtonLabel: View {
    let state: SyncState
    var syncedSystemImage: String = "waveform"

    @State private var isRotating = false

    var body: some View {
        icon
            .frame(width: 16, height: 16)
        .foregroundColor(Self.accentColor(for: state))
        .onAppear {
            isRotating = isSpinning
        }
        .onChange(of: isSpinning) { _, spinning in
            isRotating = spinning
        }
    }

    static func accentColor(for state: SyncState) -> Color {
        switch state {
        case .listening:
            return .orange
        case .synced:
            return .green
        case .outsideRange:
            return .yellow
        case .resyncing, .failed:
            return .red
        case .idle:
            return .white.opacity(0.75)
        }
    }

    @ViewBuilder
    private var icon: some View {
        if case .synced = state {
            Image(systemName: syncedSystemImage)
                .font(.system(size: 13, weight: .medium))
        } else {
            ZStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .rotationEffect(.degrees(isRotating ? 360 : 0))
                    .animation(
                        isRotating
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .easeOut(duration: 0.15),
                        value: isRotating
                    )

                Text("A")
                    .font(.system(size: 8, weight: .heavy))
                    .offset(y: -0.5)
            }
        }
    }

    private var isSpinning: Bool {
        switch state {
        case .listening, .resyncing:
            return true
        default:
            return false
        }
    }
}
