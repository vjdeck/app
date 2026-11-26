import SwiftUI

struct WebVideoImportView: View {
    @ObservedObject var playerViewModel: PlayerViewModel
    @Binding var urlText: String
    @Binding var isPresented: Bool

    @FocusState private var isURLFieldFocused: Bool
    @State private var submittedRequest = false

    private var state: WebVideoDownloadState {
        playerViewModel.webVideoDownloadState
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: stateIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 18)

            sceneContent

            switch state {
            case .validating, .downloading, .processing:
                Button {
                    submittedRequest = false
                    playerViewModel.cancelWebVideoLoad()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .failed:
                Button("Retry", action: submit)
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.cyan)
                    .keyboardShortcut(.defaultAction)
            case .idle:
                Button("Load", action: submit)
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.cyan)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isPresented = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(height: 42)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .onAppear {
            submittedRequest = state.isActive
            if !state.isActive {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    guard isPresented, !state.isActive else { return }
                    isURLFieldFocused = true
                }
            }
        }
        .onChange(of: state) { previous, current in
            if previous.isActive, current == .idle, submittedRequest {
                submittedRequest = false
                withAnimation(.easeInOut(duration: 0.18)) {
                    isPresented = false
                }
            } else if case .failed = current {
                submittedRequest = false
            }
        }
    }

    @ViewBuilder
    private var sceneContent: some View {
        switch state {
        case .idle:
            urlField
        case .validating:
            inlineStatus(label: "Checking video…")
        case .downloading(let progress):
            HStack(spacing: 7) {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.cyan)
                        .frame(width: 70)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading…")
                        .font(.system(size: 10))
                }
                if let details = progressDetails(progress) {
                    Text(details)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .processing:
            inlineStatus(label: "Finalizing video…")
        case .failed(let message):
            HStack(spacing: 6) {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)

                Button {
                    playerViewModel.cancelWebVideoLoad()
                    Task { @MainActor in
                        await Task.yield()
                        isURLFieldFocused = true
                    }
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Edit URL")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var urlField: some View {
        TextField("Paste Online Video URL", text: $urlText)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .focused($isURLFieldFocused)
            .onSubmit(submit)
    }

    private func inlineStatus(label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateIcon: String {
        if case .failed = state { return "exclamationmark.triangle.fill" }
        return "globe"
    }

    private var stateColor: Color {
        if case .failed = state { return .red }
        return .cyan
    }

    private func progressDetails(_ progress: WebVideoProgress) -> String? {
        var components: [String] = []
        if let downloaded = progress.downloadedBytes {
            if let total = progress.totalBytes {
                components.append("\(Self.byteCount(downloaded)) / \(Self.byteCount(total))")
            } else {
                components.append(Self.byteCount(downloaded))
            }
        }
        if let speed = progress.bytesPerSecond,
           speed > 0,
           let speedBytes = Int64(exactly: speed.rounded(.towardZero)) {
            components.append("\(Self.byteCount(speedBytes))/s")
        }
        if let eta = progress.etaSeconds, eta >= 0 {
            components.append("ETA \(TimeFormatter.format(seconds: Double(eta)))")
        }
        return components.isEmpty ? nil : components.joined(separator: "  •  ")
    }

    private func submit() {
        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !state.isActive else { return }
        urlText = value
        submittedRequest = playerViewModel.startWebVideoLoad(urlString: value)
    }

    private static func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

struct WebVideoToolbarButton: View {
    @ObservedObject var playerViewModel: PlayerViewModel
    let isExpanded: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        isExpanded ? Color.cyan.opacity(0.45) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )

                switch playerViewModel.webVideoDownloadState {
                case .downloading(let progress) where progress.fractionCompleted != nil:
                    circularProgress(progress.fractionCompleted ?? 0)
                case .validating, .downloading, .processing:
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                case .idle, .failed:
                    Image(systemName: "globe")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isExpanded ? .cyan : .white.opacity(0.8))
                }
            }
            .frame(width: 32, height: 26)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("l", modifiers: .command)
        .onHover { isHovering = $0 }
        .help("Open Web Video (⌘L)")
    }

    private func circularProgress(_ fraction: Double) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "globe")
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(width: 17, height: 17)
    }
}
