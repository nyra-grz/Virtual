import AppKit

/// Einstellungen: Runtime-Pfad, Prefix-Pfad, Windows-Version und Erststart-Einrichtung.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var runtimeField: NSTextField!
    private var prefixField: NSTextField!
    private var versionPopup: NSPopUpButton!
    private var runtimeStatus: NSTextField!
    private var setupButton: NSButton!
    private var setupLog: NSTextView!
    private var autoUpdateBox: NSButton!

    private let versions = ["win11", "win10", "win81", "win8", "win7", "winxp"]
    /// Hält die laufende Einrichtung, solange sie läuft.
    private var prefixSetup: PrefixSetup?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Einstellungen"
        self.init(window: window)
        build()
        observe()
    }

    private func build() {
        guard let window = window else { return }
        let v = NSView()
        window.contentView = v

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 12, weight: .medium)
            l.translatesAutoresizingMaskIntoConstraints = false
            return l
        }

        let runtimeLabel = label("Runtime-Ordner (enthält bin/virtual):")
        runtimeField = NSTextField(string: Settings.shared.runtimePath.path)
        runtimeField.translatesAutoresizingMaskIntoConstraints = false
        let runtimePick = NSButton(title: "Wählen…", target: self, action: #selector(pickRuntime))
        runtimePick.translatesAutoresizingMaskIntoConstraints = false
        runtimePick.bezelStyle = .rounded

        runtimeStatus = NSTextField(labelWithString: "")
        runtimeStatus.font = .systemFont(ofSize: 11)
        runtimeStatus.translatesAutoresizingMaskIntoConstraints = false

        let prefixLabel = label("Standard-Raum (WINEPREFIX)")
        prefixField = NSTextField(string: Settings.shared.prefixPath.path)
        prefixField.translatesAutoresizingMaskIntoConstraints = false
        let prefixPick = NSButton(title: "Wählen…", target: self, action: #selector(pickPrefix))
        prefixPick.translatesAutoresizingMaskIntoConstraints = false
        prefixPick.bezelStyle = .rounded

        let versionLabel = label("Windows-Version:")
        versionPopup = NSPopUpButton()
        versionPopup.translatesAutoresizingMaskIntoConstraints = false
        versionPopup.addItems(withTitles: versions)
        versionPopup.selectItem(withTitle: Settings.shared.windowsVersion)

        setupButton = NSButton(title: "Windows-Umgebung jetzt einrichten",
                               target: self, action: #selector(runSetup))
        setupButton.bezelStyle = .rounded
        setupButton.translatesAutoresizingMaskIntoConstraints = false

        let logScroll = NSScrollView()
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        setupLog = NSTextView()
        setupLog.isEditable = false
        setupLog.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logScroll.documentView = setupLog

        autoUpdateBox = NSButton(checkboxWithTitle: "Beim Start nach Updates suchen", target: nil, action: nil)
        autoUpdateBox.state = Settings.shared.autoUpdate ? .on : .off
        autoUpdateBox.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: "Sichern", target: self, action: #selector(saveAndClose))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        save.translatesAutoresizingMaskIntoConstraints = false

        [runtimeLabel, runtimeField, runtimePick, runtimeStatus,
         prefixLabel, prefixField, prefixPick, versionLabel, versionPopup,
         setupButton, logScroll, autoUpdateBox, save].forEach { v.addSubview($0) }

        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            runtimeLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: m),
            runtimeLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),

            runtimeField.topAnchor.constraint(equalTo: runtimeLabel.bottomAnchor, constant: 4),
            runtimeField.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            runtimePick.leadingAnchor.constraint(equalTo: runtimeField.trailingAnchor, constant: 8),
            runtimePick.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -m),
            runtimePick.centerYAnchor.constraint(equalTo: runtimeField.centerYAnchor),
            runtimePick.widthAnchor.constraint(equalToConstant: 90),

            runtimeStatus.topAnchor.constraint(equalTo: runtimeField.bottomAnchor, constant: 4),
            runtimeStatus.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),

            prefixLabel.topAnchor.constraint(equalTo: runtimeStatus.bottomAnchor, constant: 16),
            prefixLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            prefixField.topAnchor.constraint(equalTo: prefixLabel.bottomAnchor, constant: 4),
            prefixField.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            prefixPick.leadingAnchor.constraint(equalTo: prefixField.trailingAnchor, constant: 8),
            prefixPick.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -m),
            prefixPick.centerYAnchor.constraint(equalTo: prefixField.centerYAnchor),
            prefixPick.widthAnchor.constraint(equalToConstant: 90),

            versionLabel.topAnchor.constraint(equalTo: prefixField.bottomAnchor, constant: 16),
            versionLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            versionPopup.centerYAnchor.constraint(equalTo: versionLabel.centerYAnchor),
            versionPopup.leadingAnchor.constraint(equalTo: versionLabel.trailingAnchor, constant: 10),
            versionPopup.widthAnchor.constraint(equalToConstant: 120),

            setupButton.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 18),
            setupButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),

            logScroll.topAnchor.constraint(equalTo: setupButton.bottomAnchor, constant: 10),
            logScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            logScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -m),
            logScroll.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90),

            autoUpdateBox.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: m),
            autoUpdateBox.centerYAnchor.constraint(equalTo: save.centerYAnchor),

            save.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -m),
            save.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -m),
        ])
        updateRuntimeStatus()
    }

    private func updateRuntimeStatus() {
        let settings = Settings.shared
        if settings.runtimeIsInstalled {
            runtimeStatus.stringValue = "✓ Runtime gefunden."
            runtimeStatus.textColor = .systemGreen
        } else {
            runtimeStatus.stringValue = "✗ Keine Runtime. build-wine.sh oder scripts/make-runtime-from-brew.sh ausführen."
            runtimeStatus.textColor = .systemRed
        }
    }

    @objc private func pickRuntime() { pickFolder(into: runtimeField) }
    @objc private func pickPrefix() { pickFolder(into: prefixField) }

    private func pickFolder(into field: NSTextField) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.begin { resp in
            if resp == .OK, let url = panel.url { field.stringValue = url.path }
        }
    }

    @objc private func runSetup() {
        apply()
        guard Settings.shared.runtimeIsInstalled else {
            setupLog.string = "Keine Runtime vorhanden – bitte zuerst eine Runtime bauen.\n"
            return
        }
        setupLog.string = ""
        setupButton.isEnabled = false
        let setup = PrefixSetup()
        prefixSetup = setup
        setup.run(RoomStore.shared.defaultRoom)
    }

    private func apply() {
        Settings.shared.runtimePath = URL(fileURLWithPath: (runtimeField.stringValue as NSString).expandingTildeInPath)
        Settings.shared.prefixPath = URL(fileURLWithPath: (prefixField.stringValue as NSString).expandingTildeInPath)
        // Das Feld beschreibt den Standard-Raum.
        RoomStore.shared.defaultRoom.prefixPath = Settings.shared.prefixPath.path
        Settings.shared.windowsVersion = versionPopup.titleOfSelectedItem ?? "win10"
        RoomStore.shared.defaultRoom.windowsVersion = Settings.shared.windowsVersion
        RoomStore.shared.save()
        NotificationCenter.default.post(name: RoomStore.didChange, object: nil)
        Settings.shared.autoUpdate = autoUpdateBox.state == .on
        updateRuntimeStatus()
    }

    @objc private func saveAndClose() {
        apply()
        window?.performClose(nil)
    }

    private func observe() {
        NotificationCenter.default.addObserver(forName: PrefixSetup.didLog, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["room"] as? UUID == self?.prefixSetup?.room?.id,
                  let line = note.userInfo?["line"] as? String else { return }
            self?.setupLog.textStorage?.append(NSAttributedString(string: line, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.textColor]))
            self?.setupLog.scrollToEndOfDocument(nil)
        }
        NotificationCenter.default.addObserver(forName: PrefixSetup.didFinish, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["room"] as? UUID == self?.prefixSetup?.room?.id else { return }
            let status = (note.userInfo?["status"] as? Int32) ?? -1
            self?.setupButton.isEnabled = true
            let msg = status == 0 ? "\n✓ Einrichtung abgeschlossen.\n" : "\n✗ Einrichtung fehlgeschlagen (Status \(status)).\n"
            self?.setupLog.textStorage?.append(NSAttributedString(string: msg, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.textColor]))
        }
    }
}
