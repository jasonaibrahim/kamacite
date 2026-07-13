import AppKit

enum MainMenuBuilder {
    static func build(recents: RecentDocumentsMenuDelegate) -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Kamacite",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        let servicesMenu = NSMenu(title: "Services")
        appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Kamacite",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Kamacite",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        let fileMenu = NSMenu(title: "File")
        let openItem = fileMenu.addItem(
            withTitle: "Open…",
            action: #selector(DocumentController.openDocument(_:)),
            keyEquivalent: "o")
        openItem.target = DocumentController.shared
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = recents
        fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recentMenu
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        // ⌘⇧C — the byte-exact markdown source slice (DocumentEngineView).
        let copySource = editMenu.addItem(
            withTitle: "Copy as Markdown Source",
            action: NSSelectorFromString("copyMarkdownSource:"),
            keyEquivalent: "C")
        copySource.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")

        let viewMenu = NSMenu(title: "View")
        // Zoom lands on DocumentEngineView via the responder chain; a font
        // change is a re-layout, never a re-parse.
        viewMenu.addItem(
            withTitle: "Zoom In",
            action: NSSelectorFromString("zoomIn:"),
            keyEquivalent: "+")
        viewMenu.addItem(
            withTitle: "Zoom Out",
            action: NSSelectorFromString("zoomOut:"),
            keyEquivalent: "-")
        viewMenu.addItem(
            withTitle: "Actual Size",
            action: NSSelectorFromString("resetZoom:"),
            keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.miniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "")

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(
            withTitle: "Kamacite Help",
            action: #selector(NSApplication.showHelp(_:)),
            keyEquivalent: "?")

        let main = NSMenu()
        for (title, submenu) in [
            ("Kamacite", appMenu), ("File", fileMenu), ("Edit", editMenu),
            ("View", viewMenu), ("Window", windowMenu), ("Help", helpMenu),
        ] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.servicesMenu = servicesMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
        return main
    }
}

/// Populates Open Recent lazily (menuNeedsUpdate) so the recents scan never touches
/// the launch path. Recents persist via NSDocumentController's shared list — no
/// NSDocument subclass required.
final class RecentDocumentsMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(
                title: url.lastPathComponent,
                action: #selector(openRecent(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        if !urls.isEmpty {
            menu.addItem(.separator())
        }
        let clear = NSMenuItem(
            title: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)),
            keyEquivalent: "")
        clear.target = NSDocumentController.shared
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        DocumentController.shared.open(urls: [url])
    }
}
