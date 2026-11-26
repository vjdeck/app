import SwiftUI

/// Shared geometry for normal playlist filtering and FastFind.
struct PlaylistSearchField: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var isEnabled = true
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isEnabled ? "magnifyingglass" : "lock.fill")
                .foregroundColor(.white.opacity(0.3))
            TextField(isEnabled ? "Search" : "Search unavailable", text: $text)
                .focused(focus)
                .textFieldStyle(.plain)
                .foregroundColor(.white.opacity(0.8))
                .onSubmit(onSubmit)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .font(.system(size: 11))
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(Color.white.opacity(isEnabled ? 0.06 : 0.025)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(Color.white.opacity(isEnabled ? 0 : 0.08), lineWidth: 1)
            .allowsHitTesting(false))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}
