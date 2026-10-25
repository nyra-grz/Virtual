import AppKit
import CoreServices

/// Findet installierte Programme in einem Raum: Installer legen Verknüpfungen im Startmenü
/// oder auf dem öffentlichen Desktop an, genau wie unter Windows.
enum AppScanner {
    /// Verknüpfungen mit diesen Wörtern sind keine Programme, die man starten will.
    private static let ignoredWords = ["uninstall", "deinstall", "entfernen", "readme", "liesmich", "read me",
                                       "help", "hilfe", "manual", "handbuch", "documentation", "dokumentation",
                                       "website", "web site", "homepage", "license", "lizenz", "release notes", "changelog"]

    private static func isAuxiliaryName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("deinstall") { return true }
        let words = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return ignoredWords.contains { word in
            word.contains(" ") ? lower.contains(word) : words.contains(word)
        }
    }

    /// Ordner, in denen Installer Verknüpfungen ablegen. Benutzer-Desktops sind in Wine meist
    /// Links auf den Mac-Schreibtisch und bleiben deshalb außen vor.
    static func folders(of room: Room) -> [URL] {
        let fm = FileManager.default
        var list = [room.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs"),
                    room.driveC.appendingPathComponent("users/Public/Desktop")]
        let users = room.driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] where user != "Public" {
            list.append(users.appendingPathComponent("\(user)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
            let desktop = users.appendingPathComponent("\(user)/Desktop")
            if (try? desktop.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false { list.append(desktop) }
        }
        return list.filter { fm.fileExists(atPath: $0.path) }
    }

    static func scan(_ room: Room) -> [(name: String, path: String)] {
        var found: [(name: String, path: String)] = []
        var seenNames = Set<String>()
        for folder in folders(of: room) {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where url.pathExtension.lowercased() == "lnk" {
                let name = url.deletingPathExtension().lastPathComponent
                let lower = name.lowercased()
                guard !isAuxiliaryName(name) else { continue }
                // Dieselbe App im Startmenü und auf dem Desktop nur einmal zeigen.
                guard seenNames.insert(lower).inserted else { continue }
                if let target = WindowsIcon.shortcutTarget(url), !target.lowercased().hasSuffix(".exe") { continue }
                found.append((name, url.path))
            }
        }
        // Some installers only register App Paths / Uninstall and never create
        // a Start menu shortcut. Do not expose every helper .exe in Program Files.
        var targets = Set(found.compactMap { WindowsIcon.shortcutTarget(URL(fileURLWithPath: $0.path)) }
            .compactMap { WindowsIcon.unixPath($0, in: room)?.standardizedFileURL.path.lowercased() })
        for item in registeredApps(in: room) {
            guard targets.insert(item.path.lowercased()).inserted,
                  seenNames.insert(item.name.lowercased()).inserted else { continue }
            found.append(item)
        }
        return found
    }

    static func registeredApps(in room: Room) -> [(name: String, path: String)] {
        var found: [(name: String, path: String)] = []
        for file in ["system.reg", "user.reg"] {
            guard let text = try? String(contentsOf: room.prefixURL.appendingPathComponent(file), encoding: .utf8) else { continue }
            var section = "", values: [String: String] = [:]
            func finish() {
                let appPath = section.contains("\\currentversion\\app paths\\")
                let uninstall = section.contains("\\currentversion\\uninstall\\")
                guard appPath || uninstall else { return }
                var path = ((appPath ? values[""] : values["displayicon"]) ?? "").trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("\""), let end = path.dropFirst().firstIndex(of: "\"") { path = String(path[path.index(after: path.startIndex)..<end]) }
                else if let suffix = path.range(of: #",-?\d+$"#, options: .regularExpression) { path.removeSubrange(suffix) }
                // Squirrel (Discord, Slack …) registers an .ico as DisplayIcon; its launcher
                // stubs sit next to Update.exe in InstallLocation.
                if uninstall, !path.lowercased().hasSuffix(".exe"), let location = values["installlocation"],
                   let stub = launcherStub(in: location, named: values["displayname"] ?? "", room: room) {
                    path = stub
                }
                guard path.lowercased().hasSuffix(".exe"), let url = WindowsIcon.unixPath(path, in: room),
                      FileManager.default.fileExists(atPath: url.path),
                      !url.path.lowercased().hasPrefix(room.driveC.appendingPathComponent("windows").path.lowercased() + "/") else { return }
                if uninstall {
                    // DisplayIcon is not necessarily the app's launch target: runtime
                    // packages point at a repair installer in ProgramData/Package Cache.
                    guard let location = values["installlocation"], let directory = WindowsIcon.unixPath(location, in: room),
                          url.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { return }
                }
                let name = values["displayname"] ?? url.deletingPathExtension().lastPathComponent
                guard !isAuxiliaryName(name), !isAuxiliaryName(url.deletingPathExtension().lastPathComponent) else { return }
                found.append((name, url.standardizedFileURL.path))
            }
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                    finish()
                    section = String(line[line.index(after: line.startIndex)..<end]).replacingOccurrences(of: "\\\\", with: "\\").lowercased()
                    values = [:]
                } else if let equal = line.firstIndex(of: "=") {
                    let key = String(line[..<equal])
                    let encoded = String(line[line.index(after: equal)...])
                    let name = key == "@" ? "" : (try? JSONDecoder().decode(String.self, from: Data(key.utf8)))?.lowercased()
                    if let name, let value = try? JSONDecoder().decode(String.self, from: Data(encoded.utf8)) { values[name] = value }
                }
            }
            finish()
        }
        return found
    }

    /// Squirrel-Starter im Installationsordner: die .exe neben Update.exe, deren Name zum
    /// Anzeigenamen passt („GitHub Desktop“ → GitHubDesktop.exe), sonst die einzige.
    private static func launcherStub(in location: String, named displayName: String, room: Room) -> String? {
        guard let directory = WindowsIcon.unixPath(location, in: room),
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        let lower = Set(files.map { $0.lowercased() })
        guard lower.contains("update.exe") else { return nil }
        let stubs = files.filter {
            let name = $0.lowercased()
            return name.hasSuffix(".exe") && !["update.exe", "squirrel.exe"].contains(name)
                && !isAuxiliaryName(String($0.dropLast(4)))
        }
        func key(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let match = stubs.first { key(String($0.dropLast(4))) == key(displayName) } ?? (stubs.count == 1 ? stubs[0] : nil)
        guard let match else { return nil }
        return location.trimmingCharacters(in: CharacterSet(charactersIn: "\\ ")) + "\\" + match
    }

    /// Sucht neu und meldet gefundene Programme (z. B. nach einer Installation).
    @discardableResult
    static func refresh(_ room: Room, announce: Bool = true) -> [Program] {
        guard room.isReady else { return [] }
        let added = Library.shared.syncDetected(scan(room), in: room)
        if announce, !added.isEmpty {
            NotificationCenter.default.post(name: RoomWatcher.didFindApps, object: nil,
                                            userInfo: ["room": room.id, "names": added.map(\.name)])
        }
        Handoff.shared.registerLinkSchemes()
        return added
    }
}

/// Beobachtet die Verknüpfungsordner aller Räume und sucht bei Änderungen nach neuen Apps.
final class RoomWatcher {
    static let shared = RoomWatcher()
    static let didFindApps = Notification.Name("WinMacVirtual.rooms.didFindApps")

    private var streams: [UUID: FSEventStreamRef] = [:]
    private var pending: Set<UUID> = []

    func start() {
        NotificationCenter.default.addObserver(forName: RoomStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.restart()
            Handoff.shared.registerLinkSchemes()
        }
        // Wenn ein Programm (etwa ein Installer) endet, könnte es eine App hinterlassen haben.
        NotificationCenter.default.addObserver(forName: Launcher.didFinishInRoom, object: nil, queue: .main) { note in
            guard let id = note.userInfo?["room"] as? UUID else { return }
            AppScanner.refresh(RoomStore.shared.room(id: id))
        }
        NotificationCenter.default.addObserver(forName: PrefixSetup.didFinish, object: nil, queue: .main) { [weak self] note in
            self?.restart()
            guard let id = note.userInfo?["room"] as? UUID,
                  let room = RoomStore.shared.rooms.first(where: { $0.id == id }) else { return }
            AppScanner.refresh(room)
        }
        restart()
        for room in RoomStore.shared.rooms { AppScanner.refresh(room, announce: false) }
    }

    func restart() {
        for stream in streams.values {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        streams.removeAll()
        for room in RoomStore.shared.rooms { watch(room) }
    }

    private func watch(_ room: Room) {
        // Startmenü-Ordner fehlen, bis der Raum eingerichtet ist; dann reicht das C:-Laufwerk.
        // Watch the prefix root too: new Start menu folders and App Paths registry
        // registrations can appear after the watcher was first started.
        let watched = [room.prefixURL.path]
        guard FileManager.default.fileExists(atPath: watched[0]) else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let roomID = room.id
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RoomWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.changed()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, watched as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        streams[roomID] = stream
    }

    /// Mehrere Änderungen kurz hintereinander (ein Installer schreibt viele Dateien) bündeln.
    private func changed() {
        let ids = Set(RoomStore.shared.rooms.map(\.id))
        guard pending.isEmpty else { pending.formUnion(ids); return }
        pending = ids
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let rooms = self.pending
            self.pending.removeAll()
            for id in rooms { AppScanner.refresh(RoomStore.shared.room(id: id)) }
        }
    }
}
