import XCTest
import AppKit

final class StandardEditMenuTests: XCTestCase {
    func testProvidesStandardResponderChainShortcuts() throws {
        let menu = StandardEditMenu.makeMenu()
        let expected: [(String, String, Selector, NSEvent.ModifierFlags)] = [
            ("Undo", "z", Selector(("undo:")), [.command]),
            ("Redo", "z", Selector(("redo:")), [.command, .shift]),
            ("Cut", "x", #selector(NSText.cut(_:)), [.command]),
            ("Copy", "c", #selector(NSText.copy(_:)), [.command]),
            ("Paste", "v", #selector(NSText.paste(_:)), [.command]),
            ("Select All", "a", #selector(NSText.selectAll(_:)), [.command])
        ]

        for (title, key, action, modifiers) in expected {
            let item = try XCTUnwrap(menu.items.first(where: { $0.title == title }))
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers)
            XCTAssertEqual(item.action, action)
            XCTAssertNil(item.target)
        }
    }

    func testInstallKeepsSingleEditMenuImmediatelyAfterAppMenu() {
        let mainMenu = NSMenu(title: "Main")
        let appItem = NSMenuItem(title: "VJDeck", action: nil, keyEquivalent: "")
        appItem.submenu = NSMenu(title: "VJDeck")
        mainMenu.addItem(appItem)

        StandardEditMenu.install(in: mainMenu)
        StandardEditMenu.install(in: mainMenu)

        XCTAssertEqual(mainMenu.items.filter { $0.submenu?.title == "Edit" }.count, 1)
        XCTAssertEqual(mainMenu.items[1].submenu?.title, "Edit")
    }
}
