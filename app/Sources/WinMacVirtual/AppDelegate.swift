import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var mainController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        mainController = MainWindowController()
        mainController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Erststart: wenn keine eingerichtete Umgebung vorhanden ist, Einstellungen öffnen.
        if Settings.shared.runtimeIsInstalled && !Settings.shared.didInitPrefix {
            let prefixReady = FileManager.default.fileExists(
                atPath: Settings.shared.prefixPath.appendingPathComponent("drive_c").path)
            if !prefixReady { SettingsWindowController.shared.showWindow(nil) }
        }
        Updater.shared.checkOnLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Finder-Doppelklick und Drop aufs Dock-Symbol.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard mainController != nil else {
            // App startet gerade erst – kurz warten, bis das Fenster steht.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                urls.forEach { self?.mainController?.launchExternalFile($0) }
            }
            return
        }
        urls.forEach { mainController.launchExternalFile($0) }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        DispatchQueue.main.asyncAfter(deadline: .now() + (mainController == nil ? 0.4 : 0)) { [weak self] in
            self?.mainController?.launchExternalFile(url)
        }
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
    @objc private func addFromMenu() { mainController.window?.makeKeyAndOrderFront(nil); NSApp.sendAction(Selector(("addProgram")), to: mainController, from: nil) }
}
