import AppKit
import CoreServices

/// Findet installierte Programme in einem Raum: Installer legen Verknüpfungen im Startmenü
/// oder auf dem öffentlichen Desktop an, genau wie unter Windows.
enum AppScanner {
    /// Verknüpfungen mit diesen Wörtern sind keine Programme, die man starten will.
    private static let ignoredWords = ["uninstall", "deinstall", "entfernen", "readme", "liesmich", "read me",
                                       "help", "hilfe", "manual", "handbuch", "documentation", "dokumentation",
                                       "website", "web site", "homepage", "license", "lizenz", "release notes", "changelog"]

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
                guard !ignoredWords.contains(where: { lower.contains($0) }) else { continue }
                // Dieselbe App im Startmenü und auf dem Desktop nur einmal zeigen.
                guard seenNames.insert(lower).inserted else { continue }
                if let target = WindowsIcon.shortcutTarget(url), !target.lowercased().hasSuffix(".exe") { continue }
                found.append((name, url.path))
            }
        }
        return found
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
        let paths = AppScanner.folders(of: room).map(\.path)
        let watched = paths.isEmpty ? [room.driveC.path] : paths
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
            self.restart()
        }
    }
}
