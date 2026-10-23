import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var mainController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        mainController = MainWindowController()
        mainController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(forName: Handoff.didSelectProgram, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?["program"] as? UUID,
                  let program = Library.shared.programs.first(where: { $0.id == id }) else { return }
            self?.mainController.selectProgram(program)
            self?.mainController.window?.makeKeyAndOrderFront(nil)
        }
        RoomWatcher.shared.start()
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach { Handoff.shared.open($0) }
        Updater.shared.checkOnLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private var pendingURLs: [URL] = []

    // LaunchServices kann URLs vor applicationDidFinishLaunching zustellen.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard mainController != nil else { pendingURLs.append(contentsOf: urls); return }
        urls.forEach { Handoff.shared.open($0) }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        application(sender, open: [URL(fileURLWithPath: filename)])
        return true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Über Virtual", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Nach Updates suchen…", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Einstellungen…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Virtual beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "Ablage")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Programm hinzufügen…", action: #selector(addFromMenu), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Bearbeiten")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einfügen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() { SettingsWindowController.shared.showWindow(nil) }
    @objc private func checkForUpdates() { Updater.shared.check(interactive: true) }
    @objc private func addFromMenu() { mainController.window?.makeKeyAndOrderFront(nil); mainController.addProgram() }
}
