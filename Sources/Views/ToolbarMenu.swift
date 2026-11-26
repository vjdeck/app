import SwiftUI

struct ToolbarMenu<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var isHovering = false

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 32, height: 26)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }
}
