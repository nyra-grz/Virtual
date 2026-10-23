import AppKit
import UniformTypeIdentifiers

/// Native Source List und ein scrollbarer Inhalt: auch im kleinsten Fenster bleiben
/// alle Aktionen erreichbar, ohne feste Spaltenbreiten vor dem ersten Layout.
final class MainWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                  NSToolbarDelegate, NSMenuDelegate {
    private let split = NSSplitViewController()
    private let outline = NSOutlineView()
    private let detail = NSStackView()
    private let banner = NSTextField(wrappingLabelWithString: "")
    private var selected: AnyObject?
    private var announcedRoomID: UUID?
    private var observers: [NSObjectProtocol] = []
    private var setups: [UUID: PrefixSetup] = [:]
    private var setupLogs: [UUID: String] = [:]
    private var programLogs: [UUID: String] = [:]
    private var visibleLog: NSTextView?
    private var room: Room { (selected as? Program)?.room ?? (selected as? Room) ?? RoomStore.shared.defaultRoom }
    private var program: Program? { selected as? Program }
    private static let addItem = NSToolbarItem.Identifier("add")
    private static let settingsItem = NSToolbarItem.Identifier("settings")

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Virtual"
        window.minSize = NSSize(width: 820, height: 520)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        self.init(window: window)
        build()
        observe()
        selectRoom(RoomStore.shared.defaultRoom)
        window.center()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func build() {
        guard let window else { return }
        let sidebar = NSViewController()
        let sidebarScroll = NSScrollView()
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebar.view = sidebarScroll
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .medium
        outline.rowHeight = 34
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(launchSelected)
        outline.autoresizingMask = [.width, .height]
        outline.setAccessibilityLabel("Räume und Programme")
        outline.registerForDraggedTypes([.fileURL])
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        sidebarScroll.documentView = outline
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 340
        split.addSplitViewItem(sidebarItem)

        let content = NSViewController()
        let root = NSView()
        content.view = root
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 18
        detail.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(detail)
        banner.font = .systemFont(ofSize: 12, weight: .medium)
        banner.textColor = .secondaryLabelColor
        banner.setAccessibilityIdentifier("discoveryBanner")
        let layout = NSStackView(views: [banner, scroll])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 8
        layout.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(layout)
        banner.isHidden = true
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor),
            banner.widthAnchor.constraint(equalTo: layout.widthAnchor),
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            detail.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: document.topAnchor),
            detail.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        window.contentViewController = split
        let toolbar = NSToolbar(identifier: "Virtual.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let room = item as? Room { return Library.shared.programs(in: room).count }
        return item == nil ? RoomStore.shared.rooms.count : 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let room = item as? Room { return Library.shared.programs(in: room)[index] }
        return RoomStore.shared.rooms[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Room }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: (item as? Room)?.name ?? (item as? Program)?.name ?? "")
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        if let room = item as? Room {
            image.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Raum")
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.toolTip = room.prefixPath
        } else if let program = item as? Program { image.image = program.icon; title.toolTip = program.path }
        cell.addSubview(image)
        cell.addSubview(title)
        cell.imageView = image
        cell.textField = title
        let dot = NSTextField(labelWithString: (item as? Program).map { Launcher.shared.isRunning($0) } == true ? "●" : "")
        dot.textColor = .systemGreen
        dot.font = .systemFont(ofSize: 11)
        dot.setAccessibilityLabel(dot.stringValue.isEmpty ? "Beendet" : "Läuft")
        dot.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(dot)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 22), image.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -4),
            dot.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outline.selectedRow >= 0 else { return }
        selected = outline.item(atRow: outline.selectedRow) as AnyObject?
        render()
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let room = item as? Room, !dropURLs(info).isEmpty else { return [] }
        outline.setDropItem(room, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let room = item as? Room else { return false }
        let added = dropURLs(info).compactMap { Library.shared.add(url: $0, to: room) }
        if let first = added.first { selectProgram(first) }
        return !added.isEmpty
    }
    private func dropURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { ["exe", "msi"].contains($0.pathExtension.lowercased()) }
    }

    func selectRoom(_ room: Room) { select(room) }
    func selectProgram(_ program: Program) { outline.expandItem(program.room); select(program) }
    private func select(_ item: AnyObject) {
        selected = item
        let row = outline.row(forItem: item)
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row) }
        render()
    }
    private func reload() {
        let old = selected
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        if let p = old as? Program, Library.shared.programs.contains(where: { $0.id == p.id }) { selectProgram(p) }
        else if let r = old as? Room, RoomStore.shared.rooms.contains(where: { $0.id == r.id }) { selectRoom(r) }
        else { selectRoom(RoomStore.shared.defaultRoom) }
    }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let view = NSTextField(wrappingLabelWithString: text)
        view.font = .systemFont(ofSize: size, weight: weight)
        return view
    }
    private func add(_ view: NSView) {
        detail.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }
    private func row(_ views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.alignment = .centerY
        add(stack)
    }
    private func render() {
        if let id = announcedRoomID, room.id != id { banner.isHidden = true }
        visibleLog = nil
        detail.arrangedSubviews.forEach { detail.removeArrangedSubview($0); $0.removeFromSuperview() }
        if let program { renderProgram(program) } else { renderRoom(room) }
    }
    private func renderRoom(_ room: Room) {
        add(label(room.name, size: 28, weight: .bold))
        let count = Library.shared.programs(in: room).count
        let state = setups[room.id]?.isRunning == true ? "Einrichtung läuft…" : (room.isReady ? "Eingerichtet" : "Noch nicht eingerichtet")
        let subtitle = label("\(room.windowsVersion.replacingOccurrences(of: "win", with: "Windows ")) · \(count) \(count == 1 ? "App" : "Apps") · \(state)")
        subtitle.textColor = .secondaryLabelColor
        add(subtitle)
        if !room.isReady || setups[room.id]?.isRunning == true || setupLogs[room.id] != nil {
            let setup = button("Raum einrichten", #selector(setupRoom))
            setup.isEnabled = setups[room.id]?.isRunning != true && Settings.shared.runtimeIsInstalled
            row([setup])
            if !Settings.shared.runtimeIsInstalled { add(label("Keine Runtime gefunden. Bitte den Runtime-Pfad in den Einstellungen prüfen.")) }
            addLog(setupLogs[room.id] ?? "Die Einrichtung legt ein eigenes Windows-Laufwerk und eine Registry für diesen Raum an.")
        }
        add(label("Werkzeuge", size: 17, weight: .semibold))
        let tools: [(String, String)] = [
            ("Explorer", "folder"), ("Programm installieren…", "square.and.arrow.down"),
            ("Eingabeaufforderung", "terminal"), ("Systemsteuerung", "switch.2"),
            ("Registry", "list.bullet.rectangle"), ("Task-Manager", "waveform.path.ecg"),
            ("Wine-Einstellungen", "slider.horizontal.3"), ("C: im Finder", "externaldrive"),
            ("Apps suchen", "magnifyingglass"), ("Zertifikat importieren…", "checkmark.seal")]
        for start in stride(from: 0, to: tools.count, by: 2) {
            let buttons = (start..<min(start + 2, tools.count)).map { index -> NSButton in
                let b = button(tools[index].0, #selector(toolClicked(_:)))
                b.image = NSImage(systemSymbolName: tools[index].1, accessibilityDescription: nil)
                b.imagePosition = .imageLeading
                b.tag = index
                b.isEnabled = room.isReady && setups[room.id]?.isRunning != true
                b.heightAnchor.constraint(equalToConstant: 38).isActive = true
                return b
            }
            let stack = NSStackView(views: buttons)
            stack.spacing = 10
            stack.distribution = .fillEqually
            add(stack)
        }
        if count == 0 { let empty = label("Noch keine Programme. Füge eine .exe oder .msi hinzu oder installiere ein Programm. Neue Startmenü-Apps erscheinen automatisch."); empty.textColor = .secondaryLabelColor; add(empty) }
        if room.id != RoomStore.shared.defaultRoom.id {
            row([button("Umbenennen…", #selector(renameSelected)), button("Raum löschen…", #selector(deleteRoom))])
        }
    }
    private func renderProgram(_ program: Program) {
        let icon = NSImageView()
        icon.image = program.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let heading = NSStackView(views: [label(program.name, size: 26, weight: .bold), label("Raum: \(program.room.name)")])
        heading.orientation = .vertical
        heading.alignment = .leading
        let header = NSStackView(views: [icon, heading])
        header.alignment = .centerY
        header.spacing = 16
        add(header)
        let path = NSTextField(labelWithString: program.path)
        path.lineBreakMode = .byTruncatingMiddle
        path.isSelectable = true
        path.toolTip = program.path
        path.textColor = .secondaryLabelColor
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        add(path)
        let running = Launcher.shared.isRunning(program)
        let status = label(running ? "● Läuft" : (program.exists ? "Bereit zum Starten" : "Datei nicht gefunden"))
        status.textColor = running ? .systemGreen : .secondaryLabelColor
        add(status)
        let launch = button("Starten", #selector(launchSelected))
        launch.isEnabled = !running && program.exists
        let stop = button("Beenden", #selector(stopSelected))
        stop.isEnabled = running
        row([launch, stop, button("Im Finder", #selector(revealProgram))])
        let log = button("Log öffnen", #selector(revealLog))
        log.isEnabled = Launcher.shared.logURL(for: program) != nil
        row([log, button("Entfernen", #selector(removeSelected))])
        add(label("Protokoll", size: 17, weight: .semibold))
        addLog(programLogs[program.id] ?? Launcher.shared.logURL(for: program).flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Beim Start erscheint hier die Programmausgabe.")
    }
    private func addLog(_ text: String) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let log = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 190))
        log.isEditable = false
        log.isSelectable = true
        log.isVerticallyResizable = true
        log.isHorizontallyResizable = false
        log.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        log.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.autoresizingMask = [.width]
        log.textContainer?.widthTracksTextView = true
        log.textContainerInset = NSSize(width: 8, height: 8)
        log.string = text
        scroll.documentView = log
        scroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
        add(scroll)
        visibleLog = log
    }

    @objc func addProgram() {
        let targetRoom = room
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["exe", "msi"].compactMap { UTType(filenameExtension: $0) }
        panel.title = "Programm hinzufügen"
        panel.prompt = "Hinzufügen"
        panel.allowsMultipleSelection = true
        panel.message = "Programm zum Raum „\(targetRoom.name)“ hinzufügen"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Library.shared.add(url: $0, to: targetRoom) }
        if let first = added.first { selectProgram(first) }
    }
    @objc private func newRoom() {
        guard let name = askName("Neuer Raum", value: "", buttonTitle: "Erstellen") else { return }
        selectRoom(RoomStore.shared.create(name: name))
    }
    @objc private func renameSelected() {
        if let program {
            if let name = askName("Programm umbenennen", value: program.name) { Library.shared.rename(program, to: name) }
        } else if room.id != RoomStore.shared.defaultRoom.id,
                  let name = askName("Raum umbenennen", value: room.name) { RoomStore.shared.rename(room, to: name) }
    }
    private func askName(_ title: String, value: String, buttonTitle: String = "Umbenennen") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    @objc private func deleteRoom() {
        let targetRoom = room
        guard targetRoom.id != RoomStore.shared.defaultRoom.id else { return }
        guard !Launcher.shared.hasRunning(in: targetRoom), setups[targetRoom.id]?.isRunning != true else {
            showError("Bitte zuerst die Programme und Werkzeuge in diesem Raum beenden und die Einrichtung abwarten."); return
        }
        let alert = NSAlert()
        alert.messageText = "Raum „\(targetRoom.name)“ löschen?"
        alert.informativeText = "Sein Windows-Laufwerk und seine Programme werden in den Papierkorb verschoben."
        alert.addButton(withTitle: "In den Papierkorb")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        RoomStore.shared.delete(targetRoom) { [weak self] error in
            if let error { self?.showError(error.localizedDescription) }
        }
    }
    @objc private func setupRoom() {
        let targetRoom = room
        guard setups[targetRoom.id]?.isRunning != true else { return }
        let setup = PrefixSetup()
        setups[targetRoom.id] = setup
        setupLogs[targetRoom.id] = ""
        setup.run(targetRoom)
        render()
    }
    @objc private func toolClicked(_ sender: NSButton) {
        let targetRoom = room
        let commands: [Int: [String]] = [0: ["explorer"], 2: ["start", "cmd"], 3: ["control"], 4: ["regedit"], 5: ["taskmgr"], 6: ["winecfg"]]
        if let args = commands[sender.tag] { runTool(args, room: targetRoom, title: sender.title); return }
        switch sender.tag {
        case 1:
            let panel = NSOpenPanel()
            panel.title = "Programm installieren"
            panel.prompt = "Installieren"
            panel.allowedContentTypes = ["exe", "msi"].compactMap { UTType(filenameExtension: $0) }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let args = url.pathExtension.lowercased() == "msi" ? ["msiexec", "/i", Launcher.windowsPath(url.path, prefix: targetRoom.prefixURL)] : [url.path]
            runTool(args, room: targetRoom, title: url.lastPathComponent)
        case 7: NSWorkspace.shared.open(targetRoom.driveC)
        case 8: AppScanner.refresh(targetRoom)
        case 9:
            let panel = NSOpenPanel()
            panel.title = "Zertifikat importieren"
            panel.prompt = "Importieren"
            panel.allowedContentTypes = Handoff.certificateExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Handoff.shared.importCertificate(url, into: targetRoom)
        default: break
        }
    }
    private func runTool(_ args: [String], room: Room, title: String) {
        do { try Launcher.shared.runTool(args, in: room, title: title) } catch { showError(error.localizedDescription) }
    }
    @objc private func launchSelected() {
        guard let program else { return }
        programLogs[program.id] = ""
        do { try Launcher.shared.launch(program) } catch { showError(error.localizedDescription) }
    }
    @objc private func stopSelected() { if let program { Launcher.shared.stop(program) } }
    @objc private func revealProgram() { if let program { NSWorkspace.shared.activateFileViewerSelecting([program.url]) } }
    @objc private func revealLog() { if let program, let url = Launcher.shared.logURL(for: program) { NSWorkspace.shared.open(url) } }
    @objc private func removeSelected() {
        guard let program else { return }
        guard !Launcher.shared.isRunning(program) else { showError("Bitte das Programm zuerst beenden."); return }
        Library.shared.remove(program)
    }
    @objc private func openSettings() { SettingsWindowController.shared.showWindow(nil); SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil) }
    private func showError(_ text: String) { let alert = NSAlert(); alert.messageText = "Aktion nicht möglich"; alert.informativeText = text; alert.runModal() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if outline.clickedRow >= 0 { outline.selectRowIndexes(IndexSet(integer: outline.clickedRow), byExtendingSelection: false) }
        func item(_ title: String, _ action: Selector) { let i = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); i.target = self }
        if let program {
            item(Launcher.shared.isRunning(program) ? "Beenden" : "Starten", Launcher.shared.isRunning(program) ? #selector(stopSelected) : #selector(launchSelected))
            item("Im Finder zeigen", #selector(revealProgram))
            item("Umbenennen…", #selector(renameSelected))
            item("Entfernen", #selector(removeSelected))
        } else {
            item("Programm hinzufügen…", #selector(addProgram))
            if !room.isReady { item("Raum einrichten", #selector(setupRoom)) }
            if room.id != RoomStore.shared.defaultRoom.id { item("Umbenennen…", #selector(renameSelected)); item("Raum löschen…", #selector(deleteRoom)) }
            menu.addItem(.separator())
            item("Neuer Raum…", #selector(newRoom))
        }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.toggleSidebar, .sidebarTrackingSeparator, Self.addItem, .flexibleSpace, Self.settingsItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .sidebarTrackingSeparator { return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split.splitView, dividerIndex: 0) }
        if identifier == Self.addItem {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Hinzufügen"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Hinzufügen")
            let menu = NSMenu()
            for (title, action) in [("Neuer Raum…", #selector(newRoom)), ("Programm hinzufügen…", #selector(addProgram))] {
                let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); entry.target = self
            }
            item.menu = menu
            return item
        }
        if identifier == Self.settingsItem {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Einstellungen"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Einstellungen")
            item.target = self
            item.action = #selector(openSettings)
            return item
        }
        return nil
    }
    private func observe() {
        func on(_ name: Notification.Name, _ block: @escaping (Notification) -> Void) { observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: block)) }
        on(RoomStore.didChange) { [weak self] _ in self?.reload() }
        on(Library.didChange) { [weak self] _ in self?.reload() }
        on(Launcher.didChange) { [weak self] _ in self?.reload() }
        on(Launcher.didLog) { [weak self] note in
            guard let self, let id = note.userInfo?["programID"] as? UUID, let line = note.userInfo?["line"] as? String else { return }
            self.programLogs[id, default: ""] += line
            if self.program?.id == id { self.visibleLog?.textStorage?.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor])); self.visibleLog?.scrollToEndOfDocument(nil) }
        }
        on(PrefixSetup.didLog) { [weak self] note in
            guard let self, let id = note.userInfo?["room"] as? UUID, let line = note.userInfo?["line"] as? String else { return }
            self.setupLogs[id, default: ""] += line
            if self.program == nil && self.room.id == id { self.visibleLog?.textStorage?.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor])); self.visibleLog?.scrollToEndOfDocument(nil) }
        }
        on(PrefixSetup.didFinish) { [weak self] note in
            guard let self, let id = note.userInfo?["room"] as? UUID else { return }
            let status = note.userInfo?["status"] as? Int32 ?? -1
            self.setupLogs[id, default: ""] += status == 0 ? "\n✓ Einrichtung abgeschlossen.\n" : "\nEinrichtung fehlgeschlagen (Status \(status)).\n"
            self.reload()
        }
        on(RoomWatcher.didFindApps) { [weak self] note in
            guard let self, let id = note.userInfo?["room"] as? UUID, let names = note.userInfo?["names"] as? [String],
                  let room = RoomStore.shared.rooms.first(where: { $0.id == id }) else { return }
            self.announcedRoomID = id
            self.banner.stringValue = "Neu in Raum \(room.name): \(names.joined(separator: ", "))"
            self.banner.isHidden = false
            if let first = Library.shared.programs(in: room).first(where: { names.contains($0.name) }) { self.selectProgram(first) }
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
