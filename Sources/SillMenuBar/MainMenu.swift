// Modified for DUO你电脑, 2026. See NOTICE for upstream attribution.
import AppKit

/// The main menu of an app that never shows one. An accessory app (LSUIElement) has no menu bar,
/// but AppKit still routes key equivalents through the main menu, so without this ⌘C, ⌘A, ⌘F,
/// ⌘W and ⌘Q would do nothing in the Settings and Log windows.
enum MainMenu {
    @MainActor
    static func make() -> NSMenu {
        let main = NSMenu()

        let sill = submenu(in: main, title: "DUO你电脑")
        sill.addItem(withTitle: "关于 DUO你电脑", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        sill.addItem(.separator())
        sill.addItem(withTitle: "设置…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        sill.addItem(.separator())
        sill.addItem(withTitle: "退出 DUO你电脑", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = submenu(in: main, title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItem = edit.addItem(withTitle: "查找", action: nil, keyEquivalent: "")
        let find = NSMenu(title: "查找")
        // performFindPanelAction: with the NSFindPanelAction tags, which a text view with a find
        // bar (the Log window) answers.
        let actions: [(String, String, NSFindPanelAction)] = [("查找…", "f", .showFindPanel), ("查找下一个", "g", .next),
                                                              ("查找上一个", "G", .previous)]
        for (title, key, tag) in actions {
            let item = find.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
            item.tag = Int(tag.rawValue)
        }
        findItem.submenu = find

        let window = submenu(in: main, title: "窗口")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        return main
    }

    @MainActor
    private static func submenu(in main: NSMenu, title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return menu
    }
}
