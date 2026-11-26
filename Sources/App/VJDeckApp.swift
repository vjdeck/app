import SwiftUI

@main
struct VJDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("VJDeck", id: "main") {
            MainContentView()
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
                .onOpenURL { url in
                    PlaylistViewModel.shared.handleDeepLink(url)
                }
        }
        .defaultSize(width: AppDelegate.deckDefaultWidth, height: AppDelegate.deckDefaultHeight)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindowController.shared.showWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .printItem) {}
            CommandGroup(replacing: .textFormatting) {}
            CommandGroup(replacing: .help) {}
        }
    }
}
