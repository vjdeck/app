import Foundation

/// Identifiable wrapper for a Syphon server description dictionary.
struct SyphonServerInfo: Identifiable {
    let id: String
    let appName: String
    let serverName: String
    let description: [String: Any]

    var displayName: String {
        serverName.isEmpty ? appName : "\(appName) — \(serverName)"
    }

    init(_ dict: [String: Any]) {
        id = dict[SyphonServerDescriptionUUIDKey] as? String ?? UUID().uuidString
        appName = dict[SyphonServerDescriptionAppNameKey] as? String ?? "Unknown"
        serverName = dict[SyphonServerDescriptionNameKey] as? String ?? ""
        description = dict
    }
}

/// Shared singleton that observes the system-wide Syphon server directory.
final class SyphonServerBrowser: ObservableObject {
    static let shared = SyphonServerBrowser()
    @Published var servers: [SyphonServerInfo] = []

    private init() {
        refresh()
        let nc = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        nc.addObserver(forName: .SyphonServerAnnounce, object: nil, queue: nil, using: handler)
        nc.addObserver(forName: .SyphonServerRetire, object: nil, queue: nil, using: handler)
        nc.addObserver(forName: .SyphonServerUpdate, object: nil, queue: nil, using: handler)
    }

    func refresh() {
        let raw = SyphonServerDirectory.shared().servers as [[String: Any]]
        servers = raw.map { SyphonServerInfo($0) }
    }
}
