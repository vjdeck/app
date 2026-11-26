import SwiftUI

/// A compact notice inside the existing waveform area; never resizes the deck.
struct MediaLoadPreflightView: View {
    @ObservedObject var preflight: MediaLoadPreflight

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 6) {
                if preflight.state == .checking {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                    Text("Checking length…")
                } else if case .needsConfirmation(let duration) = preflight.state {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(duration == nil ? "Length unknown" : "30+ min may cause issues")
                        .accessibilityLabel(warningDetail)
                }

                Spacer(minLength: 0)

                Button { preflight.cancel() } label: {
                    buttonLabel("Cancel", primary: false, compact: geometry.size.height < 18)
                }
                if preflight.needsConfirmation {
                    Button { preflight.confirm() } label: {
                        buttonLabel("Load", primary: true, compact: geometry.size.height < 18)
                    }
                    .accessibilityLabel("Load video anyway")
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .frame(width: geometry.size.width, height: min(28, geometry.size.height))
            .background(Color.orange.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.orange.opacity(0.25), lineWidth: 1)
            }
            .frame(height: geometry.size.height)
        }
        .help(warningDetail)
    }

    private func buttonLabel(_ title: String, primary: Bool, compact: Bool) -> some View {
        Text(title)
            .padding(.horizontal, 5)
            .padding(.vertical, compact ? 1 : 3)
            .foregroundStyle(primary ? .black : .white.opacity(0.8))
            .background(primary ? Color.orange.opacity(0.85) : .white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
    }

    private var warningDetail: String {
        if preflight.state == .checking { return "Checking video length before loading." }
        let prefix = preflight.state == .needsConfirmation(duration: nil)
            ? "Video length could not be determined. " : ""
        return prefix + "VJDeck is optimized for videos up to 30 minutes. Loading this video may cause problems."
    }
}
