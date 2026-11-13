import Foundation

/// „Im Hintergrund weiterlaufen“ pro Programm: Wechselt man zu einer anderen Mac-App, meldet der
/// Mac-Treiber der Engine dem Programm sonst „nicht mehr im Vordergrund“ (WM_ACTIVATEAPP, WM_ACTIVATE,
/// WM_KILLFOCUS), und viele Spiele drosseln sich dann oder pausieren. Für Programme auf der Liste
/// `$WINEPREFIX/.virtual/stay-active` bleibt der Vordergrund einfach, wo er ist; nur die
/// Mausbegrenzung wird gelöst. Der Treiber liest die Liste bei jedem Wechsel neu, der Schalter wirkt
/// also sofort, auch bei laufenden Programmen. Wechsel zu einem anderen Windows-Programm im Raum
/// bemerkt das Programm weiterhin ganz normal.
///
/// Die Liste enthält .exe-Namen. Zu einem Programm gehören die .exe selbst (bzw. das Ziel der
/// Verknüpfung) und die anderen .exe in seinem Programmordner, weil Starter oft eine zweite .exe
/// starten. Startet die Verknüpfung ein Steam-Spiel (`steam.exe -applaunch <id>`,
/// `steam://rungameid/<id>`), zählt der Installationsordner des Spiels.
enum StayActive {
    static func listURL(for room: Room) -> URL {
        room.prefixURL.appendingPathComponent(".virtual/stay-active")
    }

    private static let queue = DispatchQueue(label: "Virtual.StayActive", qos: .utility)

    /// Schreibt die Liste eines Raums im Hintergrund neu.
    static func update(_ room: Room) {
        let programs = Library.shared.programs(in: room).filter { $0.stayActive == true }
        queue.async {
            let names = programs.flatMap { executables(for: $0) }
            do { try write(names, to: listURL(for: room)) } catch {
                NSLog("Virtual: Liste „Im Hintergrund weiterlaufen“ für %@ nicht geschrieben: %@", room.name, "\(error)")
            }
        }
    }

    static func write(_ names: [String], to url: URL) throws {
        let fm = FileManager.default
        let unique = Array(Set(names.map { $0.lowercased() })).sorted()
        guard !unique.isEmpty else {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "# Von Virtual geschrieben (Schalter „Im Hintergrund weiterlaufen“), wird überschrieben.\n"
            + unique.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Die .exe-Namen, die zu einem Programm gehören.
    static func executables(for program: Program) -> [String] {
        let room = program.room
        var target = program.url
        var arguments = ""
        switch program.url.pathExtension.lowercased() {
        case "exe": break
        case "lnk":
            guard let windowsPath = WindowsIcon.shortcutTarget(program.url),
                  let url = WindowsIcon.unixPath(windowsPath, in: room) else { return [] }
            target = url
            arguments = WindowsIcon.shortcutArguments(program.url) ?? ""
        default: return []   // .msi: Installer
        }
        guard target.pathExtension.lowercased() == "exe" else { return [] }
        if let id = steamAppID(arguments), let game = steamGameFolder(id, steam: target.deletingLastPathComponent()) {
            return executables(in: game, depth: 4)
        }
        return [target.lastPathComponent] + (programFolder(of: target, in: room).map { executables(in: $0, depth: 3) } ?? [])
    }

    /// Steam-App-ID aus „-applaunch 284160“ oder „steam://rungameid/284160“.
    static func steamAppID(_ arguments: String) -> String? {
        let pattern = #"(?:-applaunch\s+|steam://(?:rungameid|run|launch)/)(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: arguments, range: NSRange(arguments.startIndex..., in: arguments)),
              let range = Range(match.range(at: 1), in: arguments) else { return nil }
        return String(arguments[range])
    }

    /// Installationsordner eines Steam-Spiels: appmanifest_<id>.acf in einer der Steam-Bibliotheken.
    static func steamGameFolder(_ id: String, steam: URL) -> URL? {
        var libraries = [steam.appendingPathComponent("steamapps")]
        let vdf = steam.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            for path in values(of: "path", in: text) {
                let windows = path.replacingOccurrences(of: "\\\\", with: "\\")
                if let url = unixPathFromAnyDrive(windows, steam: steam) {
                    libraries.append(url.appendingPathComponent("steamapps"))
                }
            }
        }
        for library in libraries {
            let manifest = library.appendingPathComponent("appmanifest_\(id).acf")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                  let dir = values(of: "installdir", in: text).first, !dir.isEmpty else { continue }
            let folder = library.appendingPathComponent("common").appendingPathComponent(dir)
            if FileManager.default.fileExists(atPath: folder.path) { return folder }
        }
        return nil
    }

    /// Werte eines Schlüssels in Valves KeyValues-Text („"key"  "value"“).
    private static func values(of key: String, in text: String) -> [String] {
        let pattern = "\"\(key)\"\\s+\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Windows-Pfad aus libraryfolders.vdf; C: liegt im Raum (drive_c neben dem Steam-Ordner).
    private static func unixPathFromAnyDrive(_ windowsPath: String, steam: URL) -> URL? {
        var driveC = steam
        while driveC.lastPathComponent != "drive_c", driveC.pathComponents.count > 1 { driveC.deleteLastPathComponent() }
        guard driveC.lastPathComponent == "drive_c" else { return nil }
        let room = driveC.deletingLastPathComponent()
        let parts = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard parts.count >= 3, parts.dropFirst().first == ":" else { return nil }
        let rest = String(parts.dropFirst(3))
        let drive = parts.first!.lowercased()
        if drive == "c" { return driveC.appendingPathComponent(rest) }
        return room.appendingPathComponent("dosdevices/\(drive):").resolvingSymlinksInPath().appendingPathComponent(rest)
    }

    /// Eigener Ordner des Programms, in dem die anderen .exe mitzählen; nil bei Sammelordnern
    /// (Programme, windows, Benutzer, Laufwerk) und bei Dateien außerhalb von C:.
    static func programFolder(of exe: URL, in room: Room) -> URL? {
        let folder = exe.deletingLastPathComponent().standardizedFileURL
        let driveC = room.driveC.standardizedFileURL.pathComponents
        let parts = folder.pathComponents
        guard parts.count > driveC.count, Array(parts.prefix(driveC.count)) == driveC else { return nil }
        let inside = parts.dropFirst(driveC.count).map { $0.lowercased() }
        switch inside.first {
        case "windows", "users": return nil
        case "program files", "program files (x86)", "programdata": return inside.count >= 2 ? folder : nil
        default: return folder
        }
    }

    /// Alle .exe unter einem Ordner (begrenzte Tiefe, Steam-Bibliotheken ausgenommen).
    static func executables(in folder: URL, depth: Int) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let base = folder.standardizedFileURL.pathComponents.count
        var names: [String] = []
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 50_000 || names.count >= 256 { break }
            let level = url.standardizedFileURL.pathComponents.count - base
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if level >= depth || url.lastPathComponent.lowercased() == "steamapps" { walker.skipDescendants() }
                continue
            }
            if url.pathExtension.lowercased() == "exe" { names.append(url.lastPathComponent) }
        }
        return names
    }
}
