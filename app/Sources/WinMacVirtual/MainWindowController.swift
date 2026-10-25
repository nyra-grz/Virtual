import AppKit
import UniformTypeIdentifiers

/// Native Source List und ein scrollbarer Inhalt: auch im kleinsten Fenster bleiben
/// alle Aktionen erreichbar, ohne feste Spaltenbreiten vor dem ersten Layout.
final class MainWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                  NSToolbarDelegate, NSMenuDelegate {
    private let split = NSSplitViewController()
    private let outline = NSOutlineView()
    private let detail = NSStackView()
    private let contentScroll = NSScrollView()
    private let banner = NSTextField(wrappingLabelWithString: "")
    private var selected: AnyObject?
    private var announcedRoomID: UUID?
    private var observers: [NSObjectProtocol] = []
    private var setupLogs: [UUID: String] = [:]
    /// Exitstatus der letzten Einrichtung bzw. .NET-Installation je Raum.
    private var setupResults: [UUID: Int32] = [:]
    private var programLogs: [UUID: String] = [:]
    private var visibleLog: NSTextView?
    /// Spalten der Kachelraster beim letzten Aufbau; ändert sich die Fensterbreite, wird neu aufgebaut.
    private var renderedColumns = 0
    private var columns: Int { (contentScroll.documentView?.frame.width ?? 0) >= 640 ? 3 : 2 }
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
        // contentViewController schrumpft das Fenster auf die Mindestgröße; die zuletzt
        // gewählte Größe wiederherstellen, sonst mit der vorgesehenen starten.
        if !window.setFrameUsingName("Virtual.main") {
            window.setContentSize(NSSize(width: 1040, height: 720))
            window.center()
        }
        window.setFrameAutosaveName("Virtual.main")
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
        let scroll = contentScroll
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = DropDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.onDrop = { [weak self] urls in
            guard let self, self.program == nil else { return false }
            let added = urls.compactMap { Library.shared.add(url: $0, to: self.room) }
            if let first = added.first { self.selectProgram(first) }
            return !added.isEmpty
        }
        document.onWidthChange = { [weak self] in
            guard let self, self.program == nil, self.renderedColumns != 0, self.columns != self.renderedColumns else { return }
            // Nicht mitten im Layout umbauen.
            DispatchQueue.main.async { if self.program == nil, self.columns != self.renderedColumns { self.render() } }
        }
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
            .filter { Library.supportedExtensions.contains($0.pathExtension.lowercased()) }
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
    private static func windowsName(_ version: String) -> String {
        ["win11": "Windows 11", "win10": "Windows 10", "win81": "Windows 8.1", "win8": "Windows 8",
         "win7": "Windows 7", "winxp": "Windows XP"][version] ?? version
    }

    /// Abschnittstitel mit Abstand zum vorherigen Abschnitt.
    private func section(_ title: String, detail text: String? = nil) {
        if let last = detail.arrangedSubviews.last { detail.setCustomSpacing(30, after: last) }
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        var views: [NSView] = [heading]
        if let text {
            let count = NSTextField(labelWithString: text)
            count.font = .systemFont(ofSize: 13)
            count.textColor = .secondaryLabelColor
            views.append(count)
        }
        let row = NSStackView(views: views)
        row.spacing = 6
        row.alignment = .firstBaseline
        add(row)
        detail.setCustomSpacing(10, after: row)
    }

    private func groupLabel(_ title: String) {
        let text = NSTextField(labelWithString: title.uppercased())
        text.font = .systemFont(ofSize: 10, weight: .semibold)
        text.textColor = .tertiaryLabelColor
        add(text)
        detail.setCustomSpacing(6, after: text)
    }

    /// Kacheln in gleich breiten Spalten; jede Zeile so hoch wie ihre höchste Kachel.
    private func grid(_ tiles: [NSView]) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for start in stride(from: 0, to: tiles.count, by: columns) {
            var items = Array(tiles[start..<min(start + columns, tiles.count)])
            while items.count < columns { items.append(NSView()) }
            let row = NSStackView(views: items)
            row.distribution = .fillEqually
            row.spacing = 10
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        add(stack)
    }

    private func renderRoom(_ room: Room) {
        renderedColumns = columns
        let programs = Library.shared.programs(in: room)
        let settingUp = PrefixSetup.current(in: room) != nil
        let busy = Launcher.shared.hasRunning(in: room)
        let runningApps = programs.filter { Launcher.shared.isRunning($0) }.count
        let runtime = Settings.shared.runtimeIsInstalled
        let usable = room.isReady && !settingUp && runtime

        // Kopf: Name, Zustand und die wichtigsten Aktionen
        let title = NSTextField(labelWithString: room.name)
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pill: NSView
        if !runtime { pill = statusPill("Keine Runtime", color: .systemRed) }
        else if settingUp { pill = statusPill("Wird eingerichtet…", color: .systemOrange) }
        else if !room.isReady { pill = statusPill("Nicht eingerichtet", color: .systemOrange) }
        else if busy { pill = statusPill(runningApps > 1 ? "\(runningApps) Apps laufen" : "Läuft", color: .systemGreen) }
        else { pill = statusPill("Bereit", color: .systemGreen) }
        let dotnet = room.isReady ? (room.hasDotNet48 ? " · .NET 4.8" : " · Wine Mono") : ""
        let facts = NSTextField(labelWithString: "\(Self.windowsName(room.windowsVersion)) · \(programs.count) \(programs.count == 1 ? "App" : "Apps")\(dotnet)")
        facts.font = .systemFont(ofSize: 12)
        facts.textColor = .secondaryLabelColor
        let meta = NSStackView(views: [pill, facts])
        meta.spacing = 8
        let titles = NSStackView(views: [title, meta])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 5
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var header: [NSView] = [symbolBadge("square.stack.3d.up.fill", tint: .controlAccentColor, size: 52, pointSize: 23), titles]
        if busy {
            let stop = button("Alles beenden", #selector(stopRoom))
            stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
            stop.imagePosition = .imageLeading
            stop.toolTip = "Beendet alle Programme und Wine-Dienste in diesem Raum"
            header.append(stop)
        }
        let install = button("Programm installieren…", #selector(installProgram))
        install.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        install.imagePosition = .imageLeading
        install.bezelColor = .controlAccentColor
        install.isEnabled = runtime && !settingUp
        header.append(install)
        header.append(moreMenu(for: room))
        let top = NSStackView(views: header)
        top.distribution = .fill
        top.spacing = 10
        top.alignment = .centerY
        top.setCustomSpacing(14, after: header[0])
        add(top)

        if !room.isReady || settingUp || setupLogs[room.id] != nil { renderSetup(room, running: settingUp) }

        // Apps des Raums
        section("Apps", detail: programs.isEmpty ? nil : "\(programs.count)")
        if programs.isEmpty {
            renderEmptyApps(usable: usable)
        } else {
            grid(programs.map { appTile($0) })
        }

        // Windows-Werkzeuge, nach Zweck gruppiert
        section("Windows-Werkzeuge")
        typealias Tool = (String, String, String, NSColor, () -> Void)
        let files: [Tool] = [
            ("Explorer", "Dateien im Raum durchsuchen", "folder.fill", .systemBlue, { [weak self] in self?.runTool(["explorer"], room: room, title: "Explorer") }),
            ("C: im Finder", "Windows-Dateien auf dem Mac", "externaldrive.fill", .systemGray, { NSWorkspace.shared.open(room.driveC) }),
            ("Apps suchen", "Startmenü neu einlesen", "magnifyingglass", .systemPurple, { AppScanner.refresh(room) }),
            ("Zertifikat importieren…", "Stammzertifikat hinzufügen", "checkmark.seal.fill", .systemGreen, { [weak self] in self?.importCertificate(into: room) })
        ]
        let system: [Tool] = [
            ("Eingabeaufforderung", "Windows-Befehlszeile (cmd)", "terminal.fill", .darkGray, { [weak self] in self?.runTool(["start", "cmd"], room: room, title: "Eingabeaufforderung") }),
            ("Task-Manager", "Laufende Prozesse", "waveform.path.ecg", .systemRed, { [weak self] in self?.runTool(["taskmgr"], room: room, title: "Task-Manager") }),
            ("Systemsteuerung", "Software und Geräte", "switch.2", .systemTeal, { [weak self] in self?.runTool(["control"], room: room, title: "Systemsteuerung") }),
            ("Registry", "Registrierungs-Editor (regedit)", "list.bullet.rectangle.fill", .systemIndigo, { [weak self] in self?.runTool(["regedit"], room: room, title: "Registry") }),
            ("Wine-Einstellungen", "Grafik, Audio, Windows-Version", "slider.horizontal.3", .systemOrange, { [weak self] in self?.runTool(["winecfg"], room: room, title: "Wine-Einstellungen") }),
            (".NET Framework 4.8", room.hasDotNet48 ? "Echtes Microsoft .NET ist da" : "Echtes Microsoft .NET installieren", "shippingbox.fill", .systemPink, { [weak self] in self?.installDotNet(room) })
        ]
        for (name, tools) in [("Dateien", files), ("System", system)] {
            groupLabel(name)
            grid(tools.map { tool in
                let tile = ToolTile(title: tool.0, subtitle: tool.1, symbol: tool.2, tint: tool.3, action: tool.4)
                tile.isEnabled = (usable || (tool.0 == "C: im Finder" && room.isReady)) && !(tool.0 == ".NET Framework 4.8" && room.hasDotNet48)
                return tile
            })
            if let last = detail.arrangedSubviews.last { detail.setCustomSpacing(16, after: last) }
        }
    }

    private func moreMenu(for room: Room) -> NSView {
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.bezelStyle = .rounded
        (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        more.addItem(withTitle: "")
        more.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Weitere Aktionen")
        more.toolTip = "Weitere Aktionen"
        more.setAccessibilityLabel("Weitere Aktionen")
        guard let menu = more.menu else { return more }
        menu.autoenablesItems = false
        let existing = ActionMenuItem("Vorhandene .exe hinzufügen…", symbol: "plus.app") { [weak self] in self?.addProgram() }
        existing.isEnabled = true
        menu.addItem(existing)
        let graphics = NSMenuItem(title: "Grafik", action: nil, keyEquivalent: "")
        let graphicsMenu = NSMenu()
        let current = (try? String(contentsOf: room.prefixURL.appendingPathComponent(".virtual/graphics-backend"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "dxvk"
        for (name, backend) in [("Kompatibilität (DXVK)", "dxvk"), ("Metal (DXMT, experimentell)", "dxmt")] {
            let item = ActionMenuItem(name) { [weak self] in
                guard let self else { return }
                guard !Launcher.shared.hasRunning(in: room), PrefixSetup.current(in: room) == nil else {
                    self.showError("Bitte zuerst die Programme in diesem Raum beenden, bevor du die Grafik wechselst.")
                    return
                }
                self.runSetup(.graphics(backend), in: room)
            }
            item.state = current == backend ? .on : .off
            item.isEnabled = room.isReady && PrefixSetup.current(in: room) == nil
            graphicsMenu.addItem(item)
        }
        graphics.submenu = graphicsMenu
        menu.addItem(graphics)
        menu.addItem(ActionMenuItem("Neuer Raum…", symbol: "square.stack.3d.up.badge.a") { [weak self] in self?.newRoom() })
        if room.id != RoomStore.shared.defaultRoom.id {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Umbenennen…", symbol: "pencil") { [weak self] in self?.renameSelected() })
            menu.addItem(ActionMenuItem("Raum löschen…", symbol: "trash") { [weak self] in self?.deleteRoom() })
        }
        return more
    }

    private func renderSetup(_ room: Room, running: Bool) {
        let card = CardView()
        let dotnet = PrefixSetup.current(in: room)?.task == .dotnet48
        let failed = !running && (setupResults[room.id] ?? 0) != 0
        let done = room.isReady && !running && !failed
        card.fill = done ? .controlBackgroundColor : NSColor.systemOrange.withAlphaComponent(0.07)
        card.border = done ? .separatorColor : NSColor.systemOrange.withAlphaComponent(0.35)
        let title: String
        if dotnet { title = running ? "Microsoft .NET 4.8 wird installiert…" : (failed ? ".NET-Installation fehlgeschlagen" : ".NET Framework 4.8 installiert") }
        else { title = running ? "Raum wird eingerichtet…" : (failed ? "Einrichtung fehlgeschlagen" : (done ? "Einrichtung abgeschlossen" : "Dieser Raum ist noch nicht eingerichtet")) }
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let explanation = dotnet
            ? "Virtual lädt .NET 4.0 und 4.8 bei Microsoft (etwa 120 MB), ersetzt Wine Mono in diesem Raum und ergänzt die Windows-10-Teile. Das dauert etwa zehn Minuten."
            : "Virtual richtet diesen Raum beim ersten Programmstart automatisch ein. Dabei werden Windows-Umgebung, .NET und Grafikunterstützung vorbereitet. Das dauert etwa eine Minute."
        let text = NSTextField(wrappingLabelWithString: Settings.shared.runtimeIsInstalled
            ? (failed ? "Details stehen im Protokoll unten." : explanation)
            : "Keine Runtime gefunden. Bitte den Runtime-Pfad in den Einstellungen prüfen.")
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [heading, text])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        let symbol = done ? "checkmark" : (failed ? "exclamationmark.triangle.fill" : (dotnet ? "shippingbox.fill" : "wrench.and.screwdriver.fill"))
        var views: [NSView] = [symbolBadge(symbol, tint: done ? .systemGreen : .systemOrange), texts]
        if running {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            views.append(spinner)
        } else if done || (failed && room.isReady) {
            views.append(button("Ausblenden", #selector(hideSetupLog)))
        } else {
            let setup = button("Jetzt einrichten", #selector(setupRoom))
            setup.bezelColor = .controlAccentColor
            setup.isEnabled = Settings.shared.runtimeIsInstalled
            views.append(setup)
        }
        let row = NSStackView(views: views)
        row.spacing = 12
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
        if let last = detail.arrangedSubviews.last { detail.setCustomSpacing(22, after: last) }
        add(card)
        if let log = setupLogs[room.id] {
            detail.setCustomSpacing(8, after: card)
            addLog(log)
        }
    }

    private func renderEmptyApps(usable: Bool) {
        let card = CardView()
        card.fill = .clear
        let heading = NSTextField(labelWithString: "Noch keine Apps in diesem Raum")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let text = NSTextField(wrappingLabelWithString: "Installiere ein Programm oder zieh eine .exe oder .msi auf diese Seite. Apps, die sich ins Startmenü eintragen, erscheinen hier automatisch.")
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.alignment = .center
        let install = button("Programm installieren…", #selector(installProgram))
        install.bezelColor = .controlAccentColor
        install.isEnabled = Settings.shared.runtimeIsInstalled && PrefixSetup.current(in: room) == nil
        let existing = button("Vorhandene .exe hinzufügen…", #selector(addProgram))
        existing.isEnabled = true
        let buttons = NSStackView(views: [install, existing])
        buttons.spacing = 8
        let stack = NSStackView(views: [symbolBadge("square.and.arrow.down.on.square.fill", tint: .systemBlue, size: 40, pointSize: 18), heading, text, buttons])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(12, after: text)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            stack.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -40),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
        add(card)
    }

    private func appTile(_ program: Program) -> NSView {
        let running = Launcher.shared.isRunning(program)
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(running ? "Beenden" : "Starten") { [weak self] in
            if running { Launcher.shared.stop(program) } else { self?.launch(program) }
        })
        menu.addItem(ActionMenuItem("Details") { [weak self] in self?.selectProgram(program) })
        menu.addItem(ActionMenuItem("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([program.url]) })
        return AppTile(program: program, running: running,
                       onOpen: { [weak self] in self?.selectProgram(program) },
                       onToggle: { [weak self] in
                           if Launcher.shared.isRunning(program) { Launcher.shared.stop(program) } else { self?.launch(program) }
                       },
                       menu: menu)
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
        let status = label(Launcher.shared.isPreparing(program) ? "Windows-Umgebung wird vorbereitet…" : (running ? "● Läuft" : (program.exists ? "Bereit zum Starten" : "Datei nicht gefunden")))
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
        panel.allowedContentTypes = Library.supportedExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        panel.title = "Programm hinzufügen"
        panel.prompt = "Hinzufügen"
        panel.allowsMultipleSelection = true
        panel.message = "Programm zum Raum „\(targetRoom.name)“ hinzufügen"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { Library.shared.add(url: $0, to: targetRoom) }
        if let first = added.first { selectProgram(first) }
    }
    @objc fileprivate func newRoom() {
        guard let name = askName("Neuer Raum", value: "", buttonTitle: "Erstellen") else { return }
        selectRoom(RoomStore.shared.create(name: name))
    }
    @objc fileprivate func renameSelected() {
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
    @objc fileprivate func deleteRoom() {
        let targetRoom = room
        guard targetRoom.id != RoomStore.shared.defaultRoom.id else { return }
        guard !Launcher.shared.hasRunning(in: targetRoom), PrefixSetup.current(in: targetRoom) == nil else {
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
    @objc private func setupRoom() { runSetup(.setup, in: room) }
    private func runSetup(_ task: PrefixSetup.Task, in targetRoom: Room) {
        guard PrefixSetup.current(in: targetRoom) == nil else { return }
        let setup = PrefixSetup()
        setupLogs[targetRoom.id] = ""
        setupResults[targetRoom.id] = nil
        setup.run(targetRoom, task: task)
        render()
    }
    private func installDotNet(_ targetRoom: Room) {
        let alert = NSAlert()
        alert.messageText = "Microsoft .NET Framework 4.8 in „\(targetRoom.name)“ installieren?"
        alert.informativeText = "Für Programme, die mit Wine Mono nicht laufen, etwa weil sie Windows-10-Funktionen nutzen. Virtual lädt dafür etwa 120 MB bei Microsoft und ersetzt Wine Mono in diesem Raum. Das dauert etwa zehn Minuten; laufende Programme im Raum werden vorher beendet."
        alert.addButton(withTitle: "Installieren")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Launcher.shared.stopAll(in: [targetRoom]) { [weak self] in self?.runSetup(.dotnet48, in: targetRoom) }
    }
    @objc private func installProgram() {
        let targetRoom = room
        let panel = NSOpenPanel()
        panel.title = "Programm installieren"
        panel.prompt = "Installieren"
        panel.message = "Installer (.exe oder .msi) im Raum „\(targetRoom.name)“ ausführen"
        panel.allowedContentTypes = ["exe", "msi"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let program = Library.shared.add(url: url, to: targetRoom) else { showError("Die ausgewählte Datei kann nicht gelesen werden."); return }
        selectProgram(program)
        launch(program)
    }
    private func importCertificate(into targetRoom: Room) {
        let panel = NSOpenPanel()
        panel.title = "Zertifikat importieren"
        panel.prompt = "Importieren"
        panel.allowedContentTypes = Handoff.certificateExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Handoff.shared.importCertificate(url, into: targetRoom)
    }
    @objc private func stopRoom() {
        let targetRoom = room
        let alert = NSAlert()
        alert.messageText = "Alles in „\(targetRoom.name)“ beenden?"
        alert.informativeText = "Alle Windows-Programme und Hintergrunddienste dieses Raums werden sofort geschlossen. Nicht gespeicherte Daten gehen verloren."
        alert.addButton(withTitle: "Beenden")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Launcher.shared.stopAll(in: [targetRoom])
    }
    @objc private func hideSetupLog() {
        setupLogs[room.id] = nil
        render()
    }
    private func runTool(_ args: [String], room: Room, title: String) {
        do { try Launcher.shared.runTool(args, in: room, title: title) } catch { showError(error.localizedDescription) }
    }
    @objc private func launchSelected() {
        if let program { launch(program) }
    }
    private func launch(_ program: Program) {
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
        on(PrefixSetup.didChange) { [weak self] _ in self?.reload() }
        on(Launcher.didFail) { [weak self] note in
            guard let title = note.userInfo?["title"] as? String, let text = note.userInfo?["message"] as? String else { return }
            self?.showError("„\(title)“ konnte nicht erfolgreich gestartet werden.\n\n\(text)")
        }
        on(Launcher.didLog) { [weak self] note in
            guard let self, let id = note.userInfo?["programID"] as? UUID, let line = note.userInfo?["line"] as? String else { return }
            self.programLogs[id, default: ""] += line
            if self.program?.id == id { self.visibleLog?.textStorage?.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor])); self.visibleLog?.scrollToEndOfDocument(nil) }
        }
        on(PrefixSetup.didLog) { [weak self] note in
            guard let self, let id = note.userInfo?["room"] as? UUID, let line = note.userInfo?["line"] as? String else { return }
            self.setupLogs[id, default: ""] += line
            for pending in Library.shared.programs where pending.room.id == id && Launcher.shared.isPreparing(pending) {
                self.programLogs[pending.id, default: ""] += line
                if self.program?.id == pending.id {
                    self.visibleLog?.textStorage?.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor]))
                    self.visibleLog?.scrollToEndOfDocument(nil)
                }
            }
            if self.program == nil && self.room.id == id { self.visibleLog?.textStorage?.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor])); self.visibleLog?.scrollToEndOfDocument(nil) }
        }
        on(PrefixSetup.didFinish) { [weak self] note in
            guard let self, let id = note.userInfo?["room"] as? UUID else { return }
            let status = note.userInfo?["status"] as? Int32 ?? -1
            let what = (note.object as? PrefixSetup)?.task == .dotnet48 ? ".NET-Installation" : "Einrichtung"
            self.setupResults[id] = status
            self.setupLogs[id, default: ""] += status == 0 ? "\n✓ \(what) abgeschlossen.\n" : "\n\(what) fehlgeschlagen (Status \(status)).\n"
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
