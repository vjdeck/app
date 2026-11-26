import AppKit

enum StandardEditMenu {
    static let title = "Edit"

    static func install(in mainMenu: NSMenu) {
        if let existing = mainMenu.items.first(where: { $0.submenu?.title == title }) {
            mainMenu.removeItem(existing)
        }

        let rootItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        rootItem.submenu = makeMenu()
        mainMenu.insertItem(rootItem, at: min(1, mainMenu.items.count))
    }

    static func makeMenu() -> NSMenu {
        let menu = NSMenu(title: title)
        menu.addItem(item(title: "Undo", action: Selector(("undo:")), key: "z"))
        menu.addItem(item(
            title: "Redo",
            action: Selector(("redo:")),
            key: "z",
            modifiers: [.command, .shift]
        ))
        menu.addItem(.separator())
        menu.addItem(item(title: "Cut", action: #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(item(title: "Copy", action: #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(item(title: "Paste", action: #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(item(title: "Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        return menu
    }

    private static func item(
        title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }
}
