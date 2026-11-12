import AppKit

/// Native preview. File operations run off the main thread and never launch programs.
final class ProgramImportWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let source = NSPopUpButton()
    private let rooms = NSPopUpButton()
    private let scanButton = NSButton(title: "Durchsuchen", target: nil, action: nil)
    private let importButton = NSButton(title: "Importieren", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Schließen", target: nil, action: nil)
    private let move = NSButton(checkboxWithTitle: "Originale nach dem Import in den Papierkorb legen", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Wähle einen Ordner und klicke auf „Durchsuchen“.")
    private let detailsButton = NSButton(title: "Details…", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let table = NSTableView()
    private var candidates: [ProgramImport.Candidate] = []
    private var checked = Set<Int>()
    private var warnings: [String] = []
    private var targetRooms: [Room] = []
    private var cancellation: Progress?
    private var busy = false
    private var sourceFolders: [URL] = []
    var isImporting: Bool { busy }
    var onImport: (([Program]) -> Void)?
    var onClose: (() -> Void)?

    convenience init(room: Room) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Windows-Programme importieren"
        panel.minSize = NSSize(width: 640, height: 500)
        panel.isReleasedWhenClosed = false
        self.init(window: panel)
        panel.delegate = self
        build(room: room)
    }
    private func build(room: Room) {
        guard let content = window?.contentView else { return }
        source.addItems(withTitles: ["Downloads", "Schreibtisch", "Dokumente", "Alle drei Ordner", "Ordner wählen…"])
        source.target = self; source.action = #selector(sourceChanged)
        source.setAccessibilityLabel("Zu durchsuchender Ordner")
        sourceFolders = presetFolders(index: 0)
        targetRooms = RoomStore.shared.rooms
        rooms.addItems(withTitles: targetRooms.map(\.name))
        rooms.selectItem(at: targetRooms.firstIndex(where: { $0.id == room.id }) ?? 0)
        rooms.setAccessibilityLabel("Zielraum")
        for (button, action) in [(scanButton, #selector(scan)), (importButton, #selector(startImport)), (cancelButton, #selector(cancel))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        importButton.keyEquivalent = "\r"; importButton.isEnabled = false
        cancelButton.keyEquivalent = "\u{1b}"
        detailsButton.target = self; detailsButton.action = #selector(showWarnings); detailsButton.bezelStyle = .rounded; detailsButton.isHidden = true
        move.target = self; move.action = #selector(updateSummary)
        move.setAccessibilityIdentifier("importMoveOriginals")
        let heading = NSTextField(wrappingLabelWithString: "Programme auf dem Mac in einen Raum übernehmen")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "Unterordner werden nach .exe und .msi durchsucht. Lose Dateien werden einzeln, Programmordner vollständig mit DLLs und Daten kopiert. Installer musst du danach im Raum starten.")
        note.textColor = .secondaryLabelColor
        let sourceRow = NSStackView(views: [NSTextField(labelWithString: "Suchen in:"), source, scanButton]); sourceRow.spacing = 8
        let roomRow = NSStackView(views: [NSTextField(labelWithString: "In Raum:"), rooms]); roomRow.spacing = 8
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate")))
        table.headerView = nil; table.rowHeight = 56; table.style = .inset
        table.dataSource = self; table.delegate = self
        table.setAccessibilityLabel("Gefundene Programmdateien und Ordner")
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 4
        let statusRow = NSStackView(views: [spinner, status, detailsButton]); statusRow.spacing = 8
        let buttons = NSStackView(views: [NSView(), cancelButton, importButton]); buttons.spacing = 8
        let layout = NSStackView(views: [heading, note, sourceRow, roomRow, scroll, move, statusRow, buttons])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 12
        layout.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            note.widthAnchor.constraint(equalTo: layout.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: layout.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
    private func presetFolders(index: Int) -> [URL] {
        let dirs: [FileManager.SearchPathDirectory] = [.downloadsDirectory, .desktopDirectory, .documentDirectory]
        return (index == 3 ? dirs : [dirs[min(index, 2)]]).compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }
    }
    @objc private func sourceChanged() {
        defer { window?.makeKeyAndOrderFront(nil) }
        if source.indexOfSelectedItem == 4 {
            let panel = NSOpenPanel()
            panel.title = "Ordner nach Windows-Programmen durchsuchen"
            panel.message = "Wähle einen oder mehrere Ordner. Unterordner werden mit durchsucht."
            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
            panel.directoryURL = sourceFolders.first
            guard panel.runModal() == .OK else { source.selectItem(at: 0); sourceFolders = presetFolders(index: 0); clearResults(); return }
            sourceFolders = panel.urls
        } else { sourceFolders = presetFolders(index: source.indexOfSelectedItem) }
        clearResults()
    }
    private func clearResults() {
        candidates = []; checked = []; warnings = []; detailsButton.isHidden = true; table.reloadData(); importButton.isEnabled = false
        status.stringValue = sourceFolders.map(\.path).joined(separator: "\n") + "\nBereit zum Durchsuchen."
    }
    private func setBusy(_ value: Bool) {
        busy = value
        for control in [source as NSControl, rooms, scanButton, move] { control.isEnabled = !value }
        table.reloadData(); importButton.isEnabled = !value && !checked.isEmpty
        cancelButton.title = value ? "Abbrechen" : "Schließen"; cancelButton.isEnabled = true
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil); cancellation = nil }
    }
    @objc private func scan() {
        clearResults(); setBusy(true); status.stringValue = "Ordner werden durchsucht…"
        let progress = Progress(totalUnitCount: 1); cancellation = progress
        let roots = sourceFolders, excluded = [Settings.shared.root] + RoomStore.shared.rooms.map(\.prefixURL)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ProgramImport.scan(roots: roots, excluding: excluded, cancelled: { progress.isCancelled }) }
            DispatchQueue.main.async { [self] in
                setBusy(false)
                switch result {
                case .success(let scan):
                    // Nur unauffällige Funde vorauswählen: große Arbeits- oder Projektordner muss man bewusst anhaken.
                    candidates = scan.candidates; warnings = scan.warnings; checked = Set(candidates.indices.filter { candidates[$0].isSafeDefault })
                    table.reloadData(); updateSummary()
                case .failure(let error): status.stringValue = error.localizedDescription
                }
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let candidate = candidates[row]
        let check = NSButton(checkboxWithTitle: "\(candidate.name) · \(fileCount(candidate.executables.count)) · \(sizeText(candidate))", target: self, action: #selector(toggleCandidate(_:)))
        check.tag = row; check.state = checked.contains(row) ? .on : .off; check.isEnabled = !busy && candidate.blocker == nil
        var detail = candidate.source.path
        if let blocker = candidate.blocker { detail = "Nicht importierbar: \(blocker) · " + detail }
        else if !candidate.isSafeDefault { detail = "Großer Ordner, nicht vorausgewählt – bitte prüfen · " + detail }
        let path = NSTextField(labelWithString: detail)
        path.textColor = candidate.isSafeDefault ? .secondaryLabelColor : .systemOrange
        path.font = .systemFont(ofSize: 11); path.lineBreakMode = .byTruncatingMiddle; path.toolTip = detail
        let stack = NSStackView(views: [check, path]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        return stack
    }
    @objc private func toggleCandidate(_ sender: NSButton) {
        if sender.state == .on { checked.insert(sender.tag) } else { checked.remove(sender.tag) }
        updateSummary()
    }
    private func fileCount(_ count: Int) -> String { "\(count) " + (count == 1 ? "Programmdatei" : "Programmdateien") }
    private func sizeText(_ candidate: ProgramImport.Candidate) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(candidate.size), countStyle: .file)
        let files = candidate.fileCount.formatted()
        return candidate.measuredFully ? "\(bytes), \(files) Dateien" : "über \(bytes), über \(files) Dateien"
    }
    private var selectedSize: UInt64 { checked.reduce(0) { $0 + candidates[$1].size } }
    @objc private func showWarnings() {
        let alert = NSAlert()
        alert.messageText = "Übersprungene Pfade"
        alert.informativeText = warnings.prefix(20).joined(separator: "\n")
        if warnings.count > 20 { alert.informativeText += "\n… und \(warnings.count - 20) weitere." }
        alert.runModal()
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func updateSummary() {
        let count = checked.reduce(0) { $0 + candidates[$1].executables.count }
        status.stringValue = candidates.isEmpty ? "Keine .exe- oder .msi-Dateien gefunden." : "\(checked.count) Einträge ausgewählt · \(fileCount(count)) · \(ByteCountFormatter.string(fromByteCount: Int64(selectedSize), countStyle: .file))."
        let skipped = candidates.indices.filter { !candidates[$0].isSafeDefault && !checked.contains($0) }.count
        if skipped > 0 { status.stringValue += "\n\(skipped) große oder blockierte Funde sind nicht ausgewählt." }
        if !warnings.isEmpty { status.stringValue += "\n\(warnings.count) Pfade übersprungen." }
        detailsButton.isHidden = warnings.isEmpty
        status.toolTip = warnings.joined(separator: "\n")
        if move.state == .on { status.stringValue += "\nAusgewählte Ordner kommen mit ihrem gesamten Inhalt in den Papierkorb." }
        importButton.isEnabled = !busy && !checked.isEmpty
    }
    @objc private func startImport() {
        guard !busy, !checked.isEmpty, targetRooms.indices.contains(rooms.indexOfSelectedItem) else { return }
        let room = targetRooms[rooms.indexOfSelectedItem]
        guard RoomStore.shared.rooms.contains(where: { $0.id == room.id }), PrefixSetup.current(in: room) == nil else {
            status.stringValue = "Der Raum wurde entfernt oder wird gerade eingerichtet. Bitte später erneut öffnen."; return
        }
        let chosen = checked.sorted().map { candidates[$0] }, recycle = move.state == .on
        let tiles = chosen.reduce(0) { $0 + ProgramImport.libraryExecutables($1.executables).count }
        if tiles > ProgramImport.manyProgramsThreshold {
            let alert = NSAlert()
            alert.messageText = "\(tiles) Programme in die Bibliothek eintragen?"
            alert.informativeText = "Die Auswahl enthält sehr viele Programmdateien. Jede wird eine eigene Kachel in „\(room.name)“. Meist ist das ein Arbeits- oder Projektordner, kein einzelnes Programm."
            alert.addButton(withTitle: "Trotzdem importieren"); alert.addButton(withTitle: "Abbrechen")
            let response = alert.runModal()
            window?.makeKeyAndOrderFront(nil)
            guard response == .alertFirstButtonReturn else { return }
        }
        if recycle {
            let names = chosen.prefix(5).map { "• \($0.name)" }.joined(separator: "\n") + (chosen.count > 5 ? "\n• … und \(chosen.count - 5) weitere" : "")
            let alert = NSAlert()
            alert.messageText = "Originale nach dem Import in den Papierkorb legen?"
            alert.informativeText = "\(fileCount(chosen.reduce(0) { $0 + $1.executables.count })) aus \(chosen.count) Dateien/Ordnern (\(ByteCountFormatter.string(fromByteCount: Int64(selectedSize), countStyle: .file))) werden in „\(room.name)“ übernommen:\n\(names)\n\nAusgewählte Ordner werden mit ihrem gesamten Inhalt kopiert und anschließend in den Papierkorb gelegt. Das geschieht erst nach geprüfter Kopie und gespeicherter Bibliothek."
            alert.addButton(withTitle: "Importieren und verschieben"); alert.addButton(withTitle: "Abbrechen")
            let response = alert.runModal()
            window?.makeKeyAndOrderFront(nil)
            guard response == .alertFirstButtonReturn else { return }
        }
        setBusy(true); status.stringValue = "Programme werden kopiert und geprüft…"
        let progress = Progress(totalUnitCount: Int64(chosen.count)); cancellation = progress
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ProgramImport.copy(chosen, to: room.driveC, cancelled: { progress.isCancelled }, progress: { index, total in
                DispatchQueue.main.async { self.status.stringValue = "Kopieren und prüfen: \(index + 1) von \(total)…" }
            }) }
            DispatchQueue.main.async { [self] in
                switch result {
                case .failure(let error): setBusy(false); status.stringValue = error.localizedDescription
                case .success(let copies): finish(copies, in: room, recycle: recycle, cancelled: progress.isCancelled)
                }
            }
        }
    }
    private func finish(_ copies: [ProgramImport.Copy], in room: Room, recycle: Bool, cancelled: Bool) {
        do {
            guard !cancelled, RoomStore.shared.rooms.contains(where: { $0.id == room.id }), PrefixSetup.current(in: room) == nil else { throw ProgramImport.Failure.cancelled }
            let programs = try Library.shared.addImported(urls: copies.flatMap { ProgramImport.libraryExecutables($0.executables) }, to: room)
            onImport?(programs)
            if recycle {
                status.stringValue = "Import gespeichert. Originale werden in den Papierkorb gelegt…"
                cancelButton.isEnabled = false
                NSWorkspace.shared.recycle(copies.map(\.source)) { recycled, error in
                    DispatchQueue.main.async {
                        let missing = copies.filter { recycled[$0.source] == nil }
                        self.complete(count: programs.count, message: missing.isEmpty ? "Originale liegen im Papierkorb." : "\(missing.count) Original(e) konnten nicht in den Papierkorb gelegt werden und bleiben am Ursprungsort. \(error?.localizedDescription ?? "")")
                    }
                }
            } else { complete(count: programs.count, message: "Die Originale bleiben am Ursprungsort.") }
        } catch {
            let cleanup = Result { try ProgramImport.discard(copies) }
            setBusy(false); status.stringValue = "\(error.localizedDescription) Die Originale bleiben erhalten."
            if case .failure(let cleanupError) = cleanup { status.stringValue += " Kopien konnten nicht vollständig entfernt werden: \(cleanupError.localizedDescription)" }
        }
    }
    private func complete(count: Int, message: String) {
        setBusy(false); candidates = []; checked = []; table.reloadData(); importButton.isEnabled = false
        status.stringValue = "\(fileCount(count)) importiert. \(message)"
    }
    @objc private func cancel() {
        if busy { cancellation?.cancel(); cancelButton.isEnabled = false; status.stringValue = "Wird abgebrochen…" }
        else { close() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if busy { if cancelButton.isEnabled { cancel() }; return false }
        return true
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
}
