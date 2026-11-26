import SwiftUI

struct WindowCloseButton: View {
    @State private var isHovering = false

    var body: some View {
        Button {
            NSApplication.shared.keyWindow?.close()
        } label: {
            ZStack {
                Circle()
                    .fill(isHovering ? Color(red: 1, green: 0.4, blue: 0.4) : Color.red.opacity(0.5))
                    .frame(width: 14, height: 14)

                if isHovering {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.black.opacity(0.7))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
    }
}
