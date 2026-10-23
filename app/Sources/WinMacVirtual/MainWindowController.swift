import AppKit
import UniformTypeIdentifiers

/// Hauptfenster: links die Programmbibliothek, rechts Status und Logansicht.
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {

    private var tableView: NSTableView!
    private var statusDot: NSImageView!
    private var titleLabel: NSTextField!
    private var pathLabel: NSTextField!
    private var startButton: NSButton!
    private var stopButton: NSButton!
    private var revealLogButton: NSButton!
    private var logView: NSTextView!
    private var emptyLabel: NSTextField!

    private var programs: [Program] { Library.shared.programs }
    private var selected: Program? {
        let row = tableView.selectedRow
        guard row >= 0, row < programs.count else { return nil }
        return programs[row]
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Virtual"
        window.titlebarAppearsTransparent = false
        window.setFrameAutosaveName("WinMacVirtualMain")
        window.minSize = NSSize(width: 720, height: 420)
        self.init(window: window)
        buildUI()
        setupToolbar()
        registerObservers()
        window.center()
    }

    // MARK: - Aufbau

    private func buildUI() {
        guard let window = window else { return }

        // Milchglas-Hintergrund für den nativen Look.
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = effect

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: effect.topAnchor),
            split.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])

        split.addArrangedSubview(makeSidebar())
        split.addArrangedSubview(makeDetail())
        split.setPosition(260, ofDividerAt: 0)

        updateDetail()
    }

    private func makeSidebar() -> NSView {
        let container = NSView()

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 40
        tableView.style = .inset
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([.fileURL])
        tableView.doubleAction = #selector(launchSelected)
        tableView.target = self

        let col = NSTableColumn(identifier: .init("program"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)

        scroll.documentView = tableView
        container.addSubview(scroll)

        // Hinweis, wenn die Bibliothek leer ist.
        emptyLabel = NSTextField(wrappingLabelWithString: "Noch keine Programme.\n\n.exe oder .msi hierher ziehen\noder unten auf + klicken.")
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        return container
    }

    private func makeDetail() -> NSView {
        let container = NSView()
        let backing = NSVisualEffectView()
        backing.material = .contentBackground
        backing.blendingMode = .behindWindow
        backing.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backing)
        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: container.topAnchor),
            backing.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            backing.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        statusDot = NSImageView()
        statusDot.translatesAutoresizingMaskIntoConstraints = false

        titleLabel = NSTextField(labelWithString: "Kein Programm ausgewählt")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        startButton = makeButton("Starten", symbol: "play.fill", action: #selector(launchSelected))
        stopButton = makeButton("Beenden", symbol: "stop.fill", action: #selector(stopSelected))
        revealLogButton = makeButton("Log im Finder", symbol: "doc.text.magnifyingglass", action: #selector(revealLog))

        let buttons = NSStackView(views: [startButton, stopButton, revealLogButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // Logansicht
        let logScroll = NSScrollView()
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .noBorder
        logView = NSTextView()
        logView.isEditable = false
        logView.drawsBackground = true
        logView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5)
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 8, height: 8)
        logScroll.documentView = logView
        logScroll.wantsLayer = true
        logScroll.layer?.cornerRadius = 8

        backing.addSubview(statusDot)
        backing.addSubview(titleLabel)
        backing.addSubview(pathLabel)
        backing.addSubview(buttons)
        backing.addSubview(logScroll)

        NSLayoutConstraint.activate([
            statusDot.leadingAnchor.constraint(equalTo: backing.leadingAnchor, constant: 24),
            statusDot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 16),
            statusDot.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.topAnchor.constraint(equalTo: backing.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: backing.trailingAnchor, constant: -24),

            pathLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            pathLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: backing.trailingAnchor, constant: -24),

            buttons.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 18),
            buttons.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            logScroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 18),
            logScroll.leadingAnchor.constraint(equalTo: backing.leadingAnchor, constant: 24),
            logScroll.trailingAnchor.constraint(equalTo: backing.trailingAnchor, constant: -24),
            logScroll.bottomAnchor.constraint(equalTo: backing.bottomAnchor, constant: -24),
        ])
        return container
    }

    private func makeButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let b = NSButton(title: " " + title, target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    // MARK: - Toolbar

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        if #available(macOS 11.0, *) { window?.toolbarStyle = .unified }
    }

    private enum Item {
        static let add = NSToolbarItem.Identifier("add")
        static let remove = NSToolbarItem.Identifier("remove")
        static let settings = NSToolbarItem.Identifier("settings")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.add, Item.remove, .flexibleSpace, Item.settings]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.add, Item.remove, Item.settings, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Item.add:
            item.label = "Hinzufügen"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Hinzufügen")
            item.target = self; item.action = #selector(addProgram)
        case Item.remove:
            item.label = "Entfernen"
            item.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Entfernen")
            item.target = self; item.action = #selector(removeSelected)
        case Item.settings:
            item.label = "Einstellungen"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Einstellungen")
            item.target = self; item.action = #selector(openSettings)
        default:
            return nil
        }
        return item
    }

    // MARK: - Tabelle

    func numberOfRows(in tableView: NSTableView) -> Int { programs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let program = programs[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            c.addSubview(image); c.addSubview(text)
            c.imageView = image; c.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6),
                image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 28),
                image.heightAnchor.constraint(equalToConstant: 28),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.imageView?.image = program.icon
        cell.textField?.stringValue = program.name
        cell.textField?.textColor = program.exists ? .labelColor : .systemRed
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateDetail() }

    // Drag & Drop in die Liste
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        return importDrop(info.draggingPasteboard)
    }

    @discardableResult
    func importDrop(_ pasteboard: NSPasteboard) -> Bool {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        var added = false
        for url in urls where Library.shared.add(url: url) != nil { added = true }
        if added { reload() }
        return added
    }

    // MARK: - Aktionen

    @objc private func addProgram() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["exe", "msi"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Hinzufügen"
        panel.message = "Windows-Programm (.exe oder .msi) auswählen"
        panel.begin { [weak self] resp in
            guard resp == .OK else { return }
            for url in panel.urls { Library.shared.add(url: url) }
            self?.reload()
        }
    }

    @objc private func removeSelected() {
        guard let program = selected else { return }
        Library.shared.remove(program)
        reload()
    }

    @objc private func launchSelected() {
        guard let program = selected else { return }
        logView.string = ""
        do {
            try Launcher.shared.launch(program)
        } catch {
            showLaunchError(error)
        }
        updateDetail()
    }

    @objc private func stopSelected() {
        guard let program = selected else { return }
        Launcher.shared.stop(program)
    }

    @objc private func revealLog() {
        guard let program = selected, let url = Launcher.shared.logURL(for: program) else {
            NSWorkspace.shared.open(Settings.shared.logsPath)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(self)
    }

    /// Von außen (AppDelegate) aufgerufen, wenn eine Datei per Finder/Dock geöffnet wird.
    func launchExternalFile(_ url: URL) {
        guard let program = Library.shared.add(url: url) else { return }
        reload()
        if let idx = programs.firstIndex(where: { $0.id == program.id }) {
            tableView.selectRowIndexes([idx], byExtendingSelection: false)
        }
        launchSelected()
    }

    // MARK: - Darstellung aktualisieren

    private func reload() {
        tableView.reloadData()
        emptyLabel.isHidden = !programs.isEmpty
        updateDetail()
    }

    private func updateDetail() {
        emptyLabel.isHidden = !programs.isEmpty
        guard let program = selected else {
            titleLabel.stringValue = "Kein Programm ausgewählt"
            pathLabel.stringValue = ""
            statusDot.image = nil
            startButton.isEnabled = false
            stopButton.isEnabled = false
            revealLogButton.isEnabled = false
            return
        }
        titleLabel.stringValue = program.name
        pathLabel.stringValue = program.path
        let running = Launcher.shared.isRunning(program)
        let symbol = running ? "circle.fill" : "circle"
        statusDot.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusDot.contentTintColor = running ? .systemGreen : .tertiaryLabelColor
        startButton.isEnabled = !running && program.exists
        stopButton.isEnabled = running
        revealLogButton.isEnabled = true
    }

    private func showLaunchError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Start nicht möglich"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Beobachter

    private func registerObservers() {
        NotificationCenter.default.addObserver(forName: Launcher.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.tableView.reloadData()
            self?.updateDetail()
        }
        NotificationCenter.default.addObserver(forName: Launcher.didLog, object: nil, queue: .main) { [weak self] note in
            guard let self = self,
                  let id = note.userInfo?["programID"] as? UUID,
                  let line = note.userInfo?["line"] as? String,
                  self.selected?.id == id else { return }
            self.appendLog(line)
        }
    }

    private func appendLog(_ text: String) {
        logView.textStorage?.append(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.labelColor]))
        logView.scrollToEndOfDocument(nil)
    }
}
