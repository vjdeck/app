import Combine
import Foundation

/// Owns the confirmation boundary before any player, audio, or waveform work.
@MainActor
final class MediaLoadPreflight: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case needsConfirmation(duration: Double?)
    }

    static let warningDuration: Double = 30 * 60
    @Published private(set) var state: State = .idle
    @Published private(set) var title = ""
    var isActive: Bool { state != .idle }
    var needsConfirmation: Bool {
        if case .needsConfirmation = state { return true }
        return false
    }

    private let probe: @Sendable (URL) -> Double?
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var onLoad: (() -> Void)?
    private var onCancel: (() -> Void)?

    init(probe: @escaping @Sendable (URL) -> Double? = { MediaDurationProbe.duration(of: $0) }) {
        self.probe = probe
    }

    func check(url: URL, title: String, onLoad: @escaping () -> Void, onCancel: @escaping () -> Void) {
        cancel()
        let id = UUID()
        requestID = id
        self.title = title
        self.onLoad = onLoad
        self.onCancel = onCancel
        state = .checking
        let probe = probe
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let duration = probe(url)
            guard !Task.isCancelled else { return }
            await self?.didProbe(duration, requestID: id)
        }
    }

    func updateTitle(_ title: String) { self.title = title }

    func confirm() {
        guard case .needsConfirmation = state else { return }
        finish()
    }

    func cancel() {
        let action = onCancel
        reset()
        action?()
    }

    private func didProbe(_ duration: Double?, requestID: UUID) {
        guard self.requestID == requestID else { return }
        task = nil
        if let duration, duration.isFinite, duration > 0 {
            if duration < Self.warningDuration {
                finish()
            } else {
                state = .needsConfirmation(duration: duration)
            }
        } else {
            // Never fall through to an expensive load when metadata is absent.
            state = .needsConfirmation(duration: nil)
        }
    }

    private func finish() {
        let action = onLoad
        reset()
        action?()
    }

    private func reset() {
        task?.cancel()
        task = nil
        requestID = nil
        onLoad = nil
        onCancel = nil
        state = .idle
        title = ""
    }
}
