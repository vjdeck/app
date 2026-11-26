import SwiftUI

/// Local source picker for files and live Syphon inputs.
struct LocalInputMenu: View, Equatable {
    private struct ServerIdentity: Equatable {
        let id: String
        let appName: String
        let serverName: String
    }

    private let playerIdentity: ObjectIdentifier
    private let syphonInputActive: Bool
    private let syphonInputServerUUID: String?
    private let syphonFullName: String
    let servers: [SyphonServerInfo]
    private let serverIdentities: [ServerIdentity]
    private let openFile: () -> Void
    private let connectSyphonInput: (SyphonServerInfo) -> Void
    private let disconnectSyphonInput: () -> Void

    @State private var isHovering = false

    init(playerViewModel: PlayerViewModel, servers: [SyphonServerInfo]) {
        playerIdentity = ObjectIdentifier(playerViewModel)
        syphonInputActive = playerViewModel.syphonInputActive
        syphonInputServerUUID = playerViewModel.syphonInputServerUUID
        syphonFullName = playerViewModel.syphonFullName
        self.servers = servers
        serverIdentities = servers.map {
            ServerIdentity(id: $0.id, appName: $0.appName, serverName: $0.serverName)
        }
        openFile = { [weak playerViewModel] in
            playerViewModel?.openFile()
        }
        connectSyphonInput = { [weak playerViewModel] server in
            playerViewModel?.connectSyphonInput(server)
        }
        disconnectSyphonInput = { [weak playerViewModel] in
            playerViewModel?.disconnectSyphonInput()
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.playerIdentity == rhs.playerIdentity
            && lhs.syphonInputActive == rhs.syphonInputActive
            && lhs.syphonInputServerUUID == rhs.syphonInputServerUUID
            && lhs.syphonFullName == rhs.syphonFullName
            && lhs.serverIdentities == rhs.serverIdentities
    }

    /// Servers filtered to exclude this deck's own output and Master.
    private var visibleServers: [SyphonServerInfo] {
        let ownApp = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "VJDeck"
        let ownName = syphonFullName
        return servers.filter { server in
            guard server.appName == ownApp else { return true }
            return server.serverName != ownName && server.serverName != "Master"
        }
    }

    var body: some View {
        Menu {
            Button {
                openFile()
            } label: {
                Label("Open File…", systemImage: "doc")
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Menu {
                if visibleServers.isEmpty {
                    Text("No Syphon servers")
                }

                ForEach(visibleServers) { server in
                    Button {
                        if isConnected(to: server) {
                            disconnectSyphonInput()
                        } else {
                            connectSyphonInput(server)
                        }
                    } label: {
                        HStack {
                            Text(server.displayName)
                            if isConnected(to: server) {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                if syphonInputActive {
                    Divider()
                    Button("Disconnect") {
                        disconnectSyphonInput()
                    }
                }
            } label: {
                Label {
                    Text("Syphon")
                } icon: {
                    Image("SyphonIcon")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundColor(syphonInputActive ? .cyan : .white.opacity(0.8))
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
                .stroke(
                    syphonInputActive
                        ? Color.cyan.opacity(0.4)
                        : Color.white.opacity(0.08),
                    lineWidth: 1
                )
        )
        .onHover { h in isHovering = h }
        .help("Local Input")
    }

    private func isConnected(to server: SyphonServerInfo) -> Bool {
        syphonInputServerUUID == server.id
    }
}
