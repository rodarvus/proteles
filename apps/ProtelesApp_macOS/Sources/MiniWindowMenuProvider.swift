import AppKit
import MudCore

enum MiniWindowMenuProviderFactory {
    static func make() -> MiniWindowMenuProvider {
        { request in
            let show: () -> MiniWindowMenuSelection? = {
                let target = MenuTarget()
                let menu = NSMenu()
                menu.autoenablesItems = false
                append(request.items, to: menu, target: target)
                guard menu.items.contains(where: { $0.action != nil || $0.submenu != nil }) else {
                    return nil
                }
                let point = NSEvent.mouseLocation
                menu.popUp(positioning: nil, at: point, in: nil)
                return target.selection
            }
            if Thread.isMainThread { return show() }
            return DispatchQueue.main.sync(execute: show)
        }
    }

    private static func append(_ items: [MiniWindowMenuItem], to menu: NSMenu, target: MenuTarget) {
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
            } else if !item.children.isEmpty {
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                append(item.children, to: submenu, target: target)
                menu.setSubmenu(submenu, for: menuItem)
                menu.addItem(menuItem)
            } else {
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: item.disabled ? nil : #selector(MenuTarget.choose(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = target
                menuItem.isEnabled = !item.disabled
                menuItem.state = item.checked ? .on : .off
                if let selectionIndex = item.selectionIndex {
                    menuItem.representedObject = SelectionBox(title: item.title, index: selectionIndex)
                }
                menu.addItem(menuItem)
            }
        }
    }
}

private final class SelectionBox: NSObject {
    let selection: MiniWindowMenuSelection

    init(title: String, index: Int) {
        selection = MiniWindowMenuSelection(title: title, index: index)
    }
}

private final class MenuTarget: NSObject {
    var selection: MiniWindowMenuSelection?

    @objc func choose(_ sender: NSMenuItem) {
        selection = (sender.representedObject as? SelectionBox)?.selection
    }
}
