import AppKit

/// Builds the application's main menu programmatically.
/// This app has no nib, so NSApp.mainMenu must be constructed and assigned by hand
/// (before finishLaunching completes) or no menu bar — and no Cmd shortcuts — exist.
enum MainMenuBuilder {

    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(goMenuItem())
        mainMenu.addItem(favoritesMenuItem())
        mainMenu.addItem(toolsMenuItem())
        mainMenu.addItem(windowMenuItem())
        mainMenu.addItem(helpMenuItem())

        return mainMenu
    }

    /// Favorites live in UserDefaults, so the menu is rebuilt whenever they change.
    private static weak var favoritesMenu: NSMenu?

    static func rebuildFavoritesMenu() {
        guard let menu = favoritesMenu else { return }
        menu.removeAllItems()

        let addItem = menu.addItem(withTitle: L("Add Current Folder"),
                                   action: #selector(MainWindowController.addFavoriteAction(_:)),
                                   keyEquivalent: "d")
        addItem.keyEquivalentModifierMask = [.command]

        let favorites = UserDefaults.standard.stringArray(forKey: "Favorites") ?? []
        guard !favorites.isEmpty else { return }
        menu.addItem(.separator())

        for (index, path) in favorites.enumerated() {
            let item = menu.addItem(withTitle: (path as NSString).lastPathComponent,
                                    action: #selector(MainWindowController.openFavoriteAction(_:)),
                                    keyEquivalent: index < 9 ? "\(index + 1)" : "")
            item.keyEquivalentModifierMask = [.command]
            item.tag = index
            item.toolTip = path
        }

        menu.addItem(.separator())
        let clearItem = menu.addItem(withTitle: L("Clear Favorites"),
                                     action: #selector(FavoritesActions.clearFavorites(_:)),
                                     keyEquivalent: "")
        clearItem.target = FavoritesActions.shared
    }

    private static func favoritesMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("Favorites"))
        favoritesMenu = menu
        item.submenu = menu
        rebuildFavoritesMenu()
        return item
    }

    /// Target object for menu actions that have no window to route to.
    private final class FavoritesActions: NSObject {
        static let shared = FavoritesActions()
        @objc func clearFavorites(_ sender: Any?) {
            UserDefaults.standard.removeObject(forKey: "Favorites")
            MainMenuBuilder.rebuildFavoritesMenu()
        }
    }

    // MARK: - App

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        let appName = "TajArchive"

        menu.addItem(withTitle: L("menu.about"), action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("menu.preferences"), action: #selector(AppDelegate.showPreferences), keyEquivalent: ",")
        menu.addItem(withTitle: L("Setup Assistant…"), action: #selector(AppDelegate.showSetupAssistant), keyEquivalent: "")
        menu.addItem(.separator())

        let servicesItem = menu.addItem(withTitle: L("Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu

        menu.addItem(.separator())
        menu.addItem(withTitle: L("Hide %@", appName), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: L("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: L("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit %@", appName), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: - File

    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("File"))

        menu.addItem(withTitle: L("Open…"), action: #selector(MainWindowController.openDocumentAction(_:)), keyEquivalent: "o")
        menu.addItem(withTitle: L("New Archive…"), action: #selector(MainWindowController.newArchiveAction(_:)), keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Extract…"), action: #selector(MainWindowController.extractAction(_:)), keyEquivalent: "e")
        menu.addItem(withTitle: L("Test Archive"), action: #selector(MainWindowController.testAction(_:)), keyEquivalent: "t")
        menu.addItem(withTitle: L("Archive Info"), action: #selector(MainWindowController.infoAction(_:)), keyEquivalent: "i")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("New Folder in Archive…"), action: #selector(MainWindowController.newFolderInArchiveAction(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Archive Comment…"), action: #selector(MainWindowController.archiveCommentAction(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Split File…"), action: #selector(MainWindowController.splitFileAction(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Combine Files…"), action: #selector(MainWindowController.combineFilesAction(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let renameItem = menu.addItem(withTitle: L("Rename…"), action: #selector(MainWindowController.renameAction(_:)), keyEquivalent: "")
        renameItem.keyEquivalent = String(UnicodeScalar(NSF2FunctionKey)!)
        renameItem.keyEquivalentModifierMask = []
        let deleteItem = menu.addItem(withTitle: L("Delete"), action: #selector(MainWindowController.deleteAction(_:)), keyEquivalent: "\u{08}")
        deleteItem.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        item.submenu = menu
        return item
    }

    // MARK: - Edit (standard selectors restore Cmd+C/V/X/A in every text field)

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("Edit"))

        menu.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Select by Mask…"), action: #selector(MainWindowController.selectByMaskAction(_:)), keyEquivalent: "+")
        menu.addItem(withTitle: L("Deselect by Mask…"), action: #selector(MainWindowController.deselectByMaskAction(_:)), keyEquivalent: "-")

        item.submenu = menu
        return item
    }

    // MARK: - View

    private static func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("View"))

        menu.addItem(withTitle: L("Refresh"), action: #selector(MainWindowController.refreshAction(_:)), keyEquivalent: "r")
        menu.addItem(.separator())

        let dualItem = menu.addItem(withTitle: L("Two Panes"),
                                    action: #selector(MainWindowController.toggleDualPaneAction(_:)),
                                    keyEquivalent: "\\")
        dualItem.keyEquivalentModifierMask = [.command]

        let switchItem = menu.addItem(withTitle: L("Switch Pane"),
                                      action: #selector(MainWindowController.switchPaneAction(_:)),
                                      keyEquivalent: "\t")
        switchItem.keyEquivalentModifierMask = [.control]

        menu.addItem(withTitle: L("Flat View"), action: #selector(MainWindowController.toggleFlatViewAction(_:)), keyEquivalent: "l")
        menu.addItem(.separator())

        let copyItem = menu.addItem(withTitle: L("Copy To…"),
                                    action: #selector(MainWindowController.copyToOtherPaneAction(_:)),
                                    keyEquivalent: String(UnicodeScalar(NSF5FunctionKey)!))
        copyItem.keyEquivalentModifierMask = []
        let moveItem = menu.addItem(withTitle: L("Move To…"),
                                    action: #selector(MainWindowController.moveToOtherPaneAction(_:)),
                                    keyEquivalent: String(UnicodeScalar(NSF6FunctionKey)!))
        moveItem.keyEquivalentModifierMask = []

        item.submenu = menu
        return item
    }

    // MARK: - Go (Finder's shortcuts)

    private static func goMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("Go"))

        let backItem = menu.addItem(withTitle: L("Back"), action: #selector(MainWindowController.goBack), keyEquivalent: "[")
        backItem.keyEquivalentModifierMask = [.command]
        let fwdItem = menu.addItem(withTitle: L("Forward"), action: #selector(MainWindowController.goForward), keyEquivalent: "]")
        fwdItem.keyEquivalentModifierMask = [.command]
        let upItem = menu.addItem(withTitle: L("Enclosing Folder"), action: #selector(MainWindowController.goUp), keyEquivalent: "\u{F700}") // Cmd+Up
        upItem.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())

        let places: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            (L("Home"), #selector(MainWindowController.goHome(_:)), "h", [.command, .shift]),
            (L("Desktop"), #selector(MainWindowController.goDesktop(_:)), "d", [.command, .shift]),
            (L("Documents"), #selector(MainWindowController.goDocuments(_:)), "o", [.command, .shift]),
            (L("Downloads"), #selector(MainWindowController.goDownloads(_:)), "l", [.command, .option]),
            (L("Applications"), #selector(MainWindowController.goApplications(_:)), "a", [.command, .shift]),
        ]
        for (title, action, key, modifiers) in places {
            let placeItem = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            placeItem.keyEquivalentModifierMask = modifiers
        }
        menu.addItem(.separator())
        let goToItem = menu.addItem(withTitle: L("Go to Folder…"), action: #selector(MainWindowController.goToFolder(_:)), keyEquivalent: "g")
        goToItem.keyEquivalentModifierMask = [.command, .shift]

        item.submenu = menu
        return item
    }

    // MARK: - Tools

    private static func toolsMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("Tools"))

        let checksumItem = menu.addItem(withTitle: L("Checksum"), action: nil, keyEquivalent: "")
        let checksumMenu = NSMenu(title: L("Checksum"))
        for (index, algo) in HashAlgorithm.allCases.enumerated() {
            let algoItem = checksumMenu.addItem(
                withTitle: algo.rawValue,
                action: #selector(MainWindowController.hashSelectedAction(_:)),
                keyEquivalent: ""
            )
            algoItem.tag = index
        }
        checksumMenu.addItem(.separator())
        let allItem = checksumMenu.addItem(
            withTitle: L("All at once (*)"),
            action: #selector(MainWindowController.hashSelectedAction(_:)),
            keyEquivalent: ""
        )
        allItem.tag = 999
        checksumItem.submenu = checksumMenu

        menu.addItem(.separator())
        menu.addItem(withTitle: L("Benchmark…"), action: #selector(MainWindowController.benchmarkAction(_:)), keyEquivalent: "b")

        item.submenu = menu
        return item
    }

    // MARK: - Window

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("Window"))

        menu.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: L("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        NSApp.windowsMenu = menu
        item.submenu = menu
        return item
    }

    // MARK: - Help

    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("Help"))
        menu.addItem(withTitle: L("Setup Assistant…"), action: #selector(AppDelegate.showSetupAssistant), keyEquivalent: "")
        menu.addItem(withTitle: L("Show Log Files"), action: #selector(AppDelegate.showLogFolder), keyEquivalent: "")
        menu.addItem(.separator())
        if AppDelegate.websiteURL != nil {
            menu.addItem(withTitle: L("TajArchive Website"), action: #selector(AppDelegate.openWebsite), keyEquivalent: "")
        }
        if AppDelegate.supportEmail != nil {
            menu.addItem(withTitle: L("Contact Support…"), action: #selector(AppDelegate.contactSupport), keyEquivalent: "")
        }
        menu.addItem(withTitle: L("7-Zip Website"), action: #selector(AppDelegate.open7ZipWebsite), keyEquivalent: "")
        if AppDelegate.donateURL != nil {
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Support TajArchive…"), action: #selector(AppDelegate.openDonate), keyEquivalent: "")
        }
        NSApp.helpMenu = menu
        item.submenu = menu
        return item
    }
}
