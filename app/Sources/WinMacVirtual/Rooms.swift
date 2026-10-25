import AppKit

/// Ein Raum: eine eigene Windows-Umgebung (Wine-Prefix) mit eigenem C:-Laufwerk,
/// eigener Registry und eigenen Programmen.
final class Room: Codable {
    let id: UUID
    var name: String
    var prefixPath: String
    var windowsVersion: String

    init(id: UUID = UUID(), name: String, prefixPath: String, windowsVersion: String = "win10") {
        self.id = id
        self.name = name
        self.prefixPath = prefixPath
        self.windowsVersion = windowsVersion
    }

    var prefixURL: URL { URL(fileURLWithPath: prefixPath) }
    var driveC: URL { prefixURL.appendingPathComponent("drive_c") }
    /// Eingerichtet, sobald wineboot das Windows-Verzeichnis angelegt hat.
    var isReady: Bool { FileManager.default.fileExists(atPath: driveC.appendingPathComponent("windows/system32").path) }
    /// Microsofts .NET Framework 4.8 statt Wine Mono (scripts/setup-dotnet48.sh legt die Markierung an).
    var hasDotNet48: Bool { FileManager.default.fileExists(atPath: prefixURL.appendingPathComponent(".virtual/dotnet").path) }
}

/// Alle Räume, gespeichert in ~/WinMac_Virtual/rooms.json. Der erste ist „Standard“,
/// die bisherige Windows-Umgebung unter ~/WinMac_Virtual/prefix.
final class RoomStore {
    static let shared = RoomStore()
    static let didChange = Notification.Name("WinMacVirtual.rooms.didChange")

    private(set) var rooms: [Room] = []

    private var storeURL: URL { Settings.shared.root.appendingPathComponent("rooms.json") }
    private var roomsFolder: URL { Settings.shared.root.appendingPathComponent("rooms") }

    init() {
        if let data = try? Data(contentsOf: storeURL),
           let list = try? JSONDecoder().decode([Room].self, from: data), !list.isEmpty {
            rooms = list
        } else {
            rooms = [Room(name: "Standard", prefixPath: Settings.shared.prefixPath.path,
                          windowsVersion: Settings.shared.windowsVersion)]
            save()
        }
    }

    var defaultRoom: Room { rooms[0] }

    func room(id: UUID?) -> Room { rooms.first { $0.id == id } ?? defaultRoom }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(rooms) else { return }
        try? FileManager.default.createDirectory(at: Settings.shared.root, withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    private func changed() {
        save()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Legt einen neuen, noch leeren Raum an; eingerichtet wird er mit PrefixSetup.
    func create(name: String, windowsVersion: String = "win10") -> Room {
        let base = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        var folder = roomsFolder.appendingPathComponent(base.isEmpty ? "raum" : base)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = roomsFolder.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let room = Room(name: name, prefixPath: folder.appendingPathComponent("prefix").path, windowsVersion: windowsVersion)
        rooms.append(room)
        changed()
        return room
    }

    func rename(_ room: Room, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        room.name = trimmed
        changed()
    }

    /// Entfernt einen Raum aus der Liste und legt seinen Ordner in den Papierkorb
    /// (wiederherstellbar). Der Standard-Raum bleibt immer bestehen.
    func delete(_ room: Room, completion: @escaping (Error?) -> Void) {
        guard room.id != defaultRoom.id else { return }
        let folder = room.prefixURL.deletingLastPathComponent()
        let finish = { [weak self] (error: Error?) in
            DispatchQueue.main.async {
                guard let self else { return }
                if error == nil {
                    self.rooms.removeAll { $0.id == room.id }
                    Library.shared.removeAll(inRoom: room.id)
                    self.changed()
                }
                completion(error)
            }
        }
        if FileManager.default.fileExists(atPath: folder.path),
           folder.path.hasPrefix(roomsFolder.path) {
            NSWorkspace.shared.recycle([folder]) { _, error in finish(error) }
        } else {
            finish(nil)
        }
    }

    /// Die Umgebung für Wine-Aufrufe in diesem Raum.
    func environment(for room: Room) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = room.prefixPath
        // Nur echte Fehler ins Programm-Log; „fixme“ sind Wine-Notizen, keine Fehler.
        env["WINEDEBUG"] = env["WINEDEBUG"] ?? "fixme-all"
        // Kiosk-Apps als Overlay über anderen Apps statt Vollbild-Sperre (Mac-Treiber der Runtime).
        if Settings.shared.overlayEnabled { env["VIRTUAL_KIOSK_OVERLAY"] = "1" } else { env["VIRTUAL_KIOSK_OVERLAY"] = nil }
        return env
    }
}
