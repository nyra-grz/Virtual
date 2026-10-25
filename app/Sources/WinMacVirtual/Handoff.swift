import AppKit

/// Nimmt an, was der Mac an Virtual übergibt – Links aus dem Browser (z. B. steam://…),
/// Dateien aus dem Finder oder aus Downloads, Zertifikate – und gibt es an den Raum weiter,
/// dessen Windows-Programme damit umgehen können.
final class Handoff {
    static let shared = Handoff()

    /// Protokolle, die Wine selbst registriert oder die der Mac besser selbst öffnet.
    private static let systemSchemes: Set<String> = ["http", "https", "ftp", "mailto", "file", "news", "nntp", "telnet",
                                                     "ldap", "irc", "about", "javascript", "res", "mk", "its", "shell"]
    static let certificateExtensions: Set<String> = ["cer", "crt", "der", "pem", "p7b", "p7c", "pfx", "p12"]

    // MARK: - Was ein Raum kennt (aus seiner Registry)

    struct Registrations {
        var protocols: Set<String> = []
        var extensions: Set<String> = []
        var openCommands: [String: String] = [:]
        var fileClasses: [String: String] = [:]
    }

    /// Liest HKCR (HKLM\Software\Classes + HKCU\Software\Classes) aus den Registry-Dateien des Raums.
    static func registrations(of room: Room) -> Registrations {
        var result = Registrations()
        let prefix = "[Software\\\\Classes\\\\"
        for file in ["system.reg", "user.reg"] {
            guard let text = try? String(contentsOf: room.prefixURL.appendingPathComponent(file), encoding: .utf8) else { continue }
            var current: String?
            text.enumerateLines { line, _ in
                if line.hasPrefix("[") {
                    current = nil
                    guard line.hasPrefix(prefix), let close = line.firstIndex(of: "]") else { return }
                    let key = line[line.index(line.startIndex, offsetBy: prefix.count)..<close]
                    current = key.lowercased()
                    if !key.contains("\\"), key.hasPrefix(".") { result.extensions.insert(String(key.dropFirst()).lowercased()) }
                } else if let key = current {
                    if line.hasPrefix("\"URL Protocol\""), !key.contains("\\"), !key.hasPrefix(".") {
                        result.protocols.insert(key)
                    }
                    if !key.contains("\\"), key.hasPrefix("."), line.hasPrefix("@="),
                       let value = registryString(String(line.dropFirst(2))) {
                        result.fileClasses[String(key.dropFirst())] = value.lowercased()
                    }
                    let commandSuffix = "\\\\shell\\\\open\\\\command"
                    if key.hasSuffix(commandSuffix), line.hasPrefix("@="),
                       let value = registryString(String(line.dropFirst(2))) {
                        result.openCommands[String(key.dropLast(commandSuffix.count))] = value
                    }
                }
            }
        }
        return result
    }

    /// Wine-Registry-Strings verwenden dieselben Quote-/Backslash-Escapes wie JSON.
    /// str(2): kennzeichnet REG_EXPAND_SZ.
    private static func registryString(_ value: String) -> String? {
        guard let firstQuote = value.firstIndex(of: "\"") else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(value[firstQuote...].utf8))
    }

    /// Windows-Quoting auflösen, dann erst Platzhalter ersetzen: Ein Link bleibt ein
    /// einzelnes Argument, auch mit Leerzeichen, Anführungszeichen oder Shell-Zeichen.
    /// https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-commandlinetoargvw
    static func registeredArguments(_ command: String, item: String) -> [String] {
        let chars = Array(command)
        var args: [String] = [], token = ""
        var quoted = false, started = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if !quoted && (c == " " || c == "\t") {
                if started { args.append(token); token = ""; started = false }
                i += 1
                continue
            }
            started = true
            var slashes = 0
            while i < chars.count && chars[i] == "\\" { slashes += 1; i += 1 }
            if i < chars.count && chars[i] == "\"" {
                token += String(repeating: "\\", count: slashes / 2)
                if slashes % 2 == 1 { token.append("\"") }
                else if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { token.append("\""); i += 1 }
                else { quoted.toggle() }
                i += 1
            } else {
                token += String(repeating: "\\", count: slashes)
                if i < chars.count && (quoted || (chars[i] != " " && chars[i] != "\t")) {
                    token.append(chars[i]); i += 1
                }
            }
        }
        if started { args.append(token) }
        let placeholders = try! NSRegularExpression(pattern: "%[1lLuU*]")
        return args.map { arg in
            placeholders.stringByReplacingMatches(in: arg, range: NSRange(arg.startIndex..., in: arg),
                                                   withTemplate: NSRegularExpression.escapedTemplate(for: item))
        }
    }

    private static func isCustomScheme(_ scheme: String) -> Bool {
        guard let first = scheme.first, first.isLetter, !systemSchemes.contains(scheme),
              !scheme.hasPrefix("ms-") else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
    }

    // MARK: - Links bei macOS anmelden

    private var registering = false

    /// Trägt die Link-Protokolle aller Räume in die Info.plist ein, damit Browser solche Links
    /// an Virtual geben. Nach jeder App-Suche aufgerufen; ändert nur etwas, wenn neue dazukamen.
    func registerLinkSchemes() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", !registering else { return }
        var schemes = Set<String>()
        for room in RoomStore.shared.rooms where room.isReady {
            schemes.formUnion(Self.registrations(of: room).protocols.filter(Self.isCustomScheme))
        }
        let previousHandlers = schemes.reduce(into: [String: URL]()) { handlers, scheme in
            if let url = URL(string: "\(scheme):"), let handler = NSWorkspace.shared.urlForApplication(toOpen: url) {
                handlers[scheme] = handler
            }
        }
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              var plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return }
        let types = plist["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let current = Set(types.first?["CFBundleURLSchemes"] as? [String] ?? [])
        guard current != schemes else { return }

        plist["CFBundleURLTypes"] = schemes.isEmpty ? nil :
            [["CFBundleURLName": "Windows-Links", "CFBundleURLSchemes": schemes.sorted()]]
        guard let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? newData.write(to: plistURL, options: .atomic)) != nil else { return }

        registering = true
        let added = schemes.subtracting(current)
        DispatchQueue.global(qos: .utility).async {
            // Die geänderte Info.plist braucht eine neue (Ad-hoc-)Signatur, dann muss macOS sie neu einlesen.
            Self.run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
            Self.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                     ["-f", bundle.path])
            DispatchQueue.main.async {
                self.registering = false
                for scheme in added {
                    // Nur übernehmen, was noch kein Mac-Programm öffnet (z. B. nicht steam://, wenn Steam für Mac da ist).
                    guard previousHandlers[scheme] == nil || previousHandlers[scheme] == bundle else { continue }
                    NSWorkspace.shared.setDefaultApplication(at: bundle, toOpenURLsWithScheme: scheme) { _ in }
                }
                self.registerLinkSchemes()
            }
        }
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return }
    }

    // MARK: - Öffnen

    func open(_ url: URL) {
        if url.isFileURL { openFile(url) } else { openLink(url) }
    }

    private func openLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        let rooms = RoomStore.shared.rooms.filter { $0.isReady && Self.registrations(of: $0).protocols.contains(scheme) }
        guard !rooms.isEmpty else {
            show("Kein Programm für diesen Link", "Keine App in deinen Räumen kann „\(scheme):“-Links öffnen.")
            return
        }
        guard let room = chooseRoom(rooms, message: "„\(scheme):“-Link öffnen in …") else { return }
        // Wine 11 löst HKCU\Software\Classes nicht zuverlässig über HKCR auf.
        // Den registrierten Befehl direkt starten, ohne ihn durch cmd zu schleusen.
        let command = Self.registrations(of: room).openCommands[scheme]
        let args = command.map { Self.registeredArguments($0, item: url.absoluteString) } ?? []
        runTool(args.first?.isEmpty == false ? args : ["start", url.absoluteString], in: room, title: "Link \(scheme)")
    }

    private func openFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        let ready = RoomStore.shared.rooms.filter(\.isReady)

        if Library.supportedExtensions.contains(ext) {
            let owner = RoomStore.shared.rooms.first { url.path.hasPrefix($0.driveC.path + "/") }
            guard let room = owner ?? chooseRoom(RoomStore.shared.rooms, message: "„\(name)“ starten in …"),
                  let program = Library.shared.add(url: url, to: room) else { return }
            NotificationCenter.default.post(name: Self.didSelectProgram, object: nil, userInfo: ["program": program.id])
            do { try Launcher.shared.launch(program) } catch { show("Start nicht möglich", error.localizedDescription) }
            return
        }
        if Self.certificateExtensions.contains(ext) {
            importCertificate(url)
            return
        }
        // Eine Verknüpfung oder Datei aus einem Raum gehört in diesen Raum.
        if let owner = ready.first(where: { url.path.hasPrefix($0.driveC.path + "/") }) {
            openDocument(url, in: owner)
            return
        }
        let handlers = ready.filter { Self.registrations(of: $0).extensions.contains(ext) }
        guard let room = chooseRoom(handlers.isEmpty ? ready : handlers, message: "„\(name)“ öffnen in …") else { return }
        openDocument(url, in: room)
    }

    private func openDocument(_ url: URL, in room: Room) {
        let registrations = Self.registrations(of: room)
        let fileClass = registrations.fileClasses[url.pathExtension.lowercased()]
        let command = fileClass.flatMap { registrations.openCommands[$0] }
        let path = Launcher.windowsPath(url.path, prefix: room.prefixURL)
        let args = command.map { Self.registeredArguments($0, item: path) } ?? []
        runTool(args.first?.isEmpty == false ? args : ["start", "/unix", url.path], in: room, title: url.lastPathComponent)
    }

    static let didSelectProgram = Notification.Name("WinMacVirtual.handoff.didSelectProgram")

    private func runTool(_ args: [String], in room: Room, title: String) {
        do { try Launcher.shared.runTool(args, in: room, title: title) } catch { show("Öffnen nicht möglich", error.localizedDescription) }
    }

    // MARK: - Zertifikate

    /// Importiert Zertifikate (.cer/.crt/.pem/.der/.p7b, .pfx/.p12 mit Passwort) in den
    /// Windows-Zertifikatspeicher eines Raums – über das mitgelieferte certimport.exe.
    func importCertificate(_ url: URL, into presetRoom: Room? = nil) {
        guard let helper = Bundle.main.url(forResource: "certimport", withExtension: "exe") else {
            show("Zertifikatsimport nicht verfügbar", "Diese Version von Virtual wurde ohne certimport.exe gebaut (mingw-w64 fehlte).")
            return
        }
        let ready = RoomStore.shared.rooms.filter(\.isReady)
        guard !ready.isEmpty else { show("Kein Raum eingerichtet", "Richte zuerst einen Raum ein."); return }
        guard let room = presetRoom ?? chooseRoom(ready, message: "Zertifikat „\(url.lastPathComponent)“ importieren in …") else { return }

        var password = ""
        if ["pfx", "p12"].contains(url.pathExtension.lowercased()) {
            let alert = NSAlert()
            alert.messageText = "Passwort für „\(url.lastPathComponent)“"
            alert.informativeText = "Die Datei enthält einen privaten Schlüssel und ist meist mit einem Passwort geschützt."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Importieren")
            alert.addButton(withTitle: "Abbrechen")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            password = field.stringValue
        } else {
            let alert = NSAlert()
            alert.messageText = "Zertifikat im Raum „\(room.name)“ installieren?"
            alert.informativeText = "Selbst signierte Zertifikate werden als vertrauenswürdige Stammzertifikate installiert. Programme in diesem Raum vertrauen dann allem, was damit signiert ist – nur bei Zertifikaten aus sicherer Quelle tun."
            alert.addButton(withTitle: "Installieren")
            alert.addButton(withTitle: "Abbrechen")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let process = Process()
        process.executableURL = Settings.shared.virtualBinary
        process.arguments = [helper.path, Launcher.windowsPath(url.path, prefix: room.prefixURL)]
        process.environment = RoomStore.shared.environment(for: room)
        let input = Pipe()
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("virtual-cert-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else { show("Import fehlgeschlagen", "Temporäres Protokoll konnte nicht angelegt werden."); return }
        process.standardInput = input
        // Wine-Dienste können stdout erben. Eine Datei vermeidet das Warten auf Pipe-EOF.
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { proc in
            try? output.close()
            let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: outputURL)
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    self.show("Zertifikat importiert", text.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    self.show("Import fehlgeschlagen", text.isEmpty ? "certimport.exe meldete Status \(proc.terminationStatus)." : text)
                }
            }
        }
        do {
            try process.run()
            input.fileHandleForWriting.write((password + "\n").data(using: .utf8)!)
            try? input.fileHandleForWriting.close()
        } catch {
            try? output.close()
            try? input.fileHandleForWriting.close()
            try? FileManager.default.removeItem(at: outputURL)
            show("Import fehlgeschlagen", error.localizedDescription)
        }
    }

    // MARK: - Hilfen

    /// Fragt nach dem Raum, wenn mehrere in Frage kommen.
    func chooseRoom(_ rooms: [Room], message: String) -> Room? {
        guard !rooms.isEmpty else { show("Kein passender Raum", "Richte zuerst einen passenden Raum ein."); return nil }
        if rooms.count == 1 { return rooms.first }
        let alert = NSAlert()
        alert.messageText = message
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItems(withTitles: rooms.map(\.name))
        alert.accessoryView = popup
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return rooms[popup.indexOfSelectedItem]
    }

    private func show(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
