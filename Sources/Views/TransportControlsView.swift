import SwiftUI

struct TransportControlsView: View {
    @ObservedObject var playerViewModel: PlayerViewModel

    var body: some View {
        HStack(spacing: 4) {
            DarkButton(
                icon: playerViewModel.playbackState == .playing ? "pause.fill" : "play.fill",
                isActive: playerViewModel.playbackState == .playing
            ) {
                playerViewModel.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])

            DarkButton(icon: "stop.fill") {
                playerViewModel.stop()
            }

            DarkButton(icon: "repeat", isActive: playerViewModel.isLooping) {
                playerViewModel.isLooping.toggle()
            }
            .keyboardShortcut("l", modifiers: .command)
        }
    }
}

// MARK: - Custom dark button style

struct DarkButton: View {
    let icon: String
    var isActive: Bool = false
    var activeColor: Color = .cyan
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isActive ? activeColor : .white.opacity(0.8))
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isActive ? activeColor.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
    }
}
