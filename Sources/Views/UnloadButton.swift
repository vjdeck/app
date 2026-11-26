import SwiftUI

struct UnloadButton: View {
    @ObservedObject var playerViewModel: PlayerViewModel
    @State private var isHovering = false

    private var isEnabled: Bool {
        (playerViewModel.isVideoLoaded || playerViewModel.syphonInputActive)
            && !playerViewModel.isMediaChangeBlocked
    }

    var body: some View {
        Button {
            if playerViewModel.syphonInputActive {
                playerViewModel.disconnectSyphonInput()
            }
            playerViewModel.unloadVideo()
        } label: {
            Image(systemName: "eject")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isEnabled && isHovering ? .white.opacity(0.7) : isEnabled ? .white.opacity(0.5) : .white.opacity(0.2))
                .frame(minWidth: 24, minHeight: 26)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(
            playerViewModel.isMediaChangeBlocked
                ? "Pause playback or unlock to eject"
                : "Eject media"
        )
    }
}
