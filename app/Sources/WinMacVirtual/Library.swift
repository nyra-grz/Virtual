import AppKit

/// Ein Windows-Programm in der Bibliothek.
final class Program: Codable {
    let id: UUID
    var name: String
    /// Pfad zur .exe/.msi als absoluter Dateipfad.
    var path: String
    /// Optionale Sicherheits-Bookmark-Daten, damit der Zugriff über Neustarts hinweg erhalten bleibt.
    var bookmark: Data?
    /// Raum, in dem das Programm läuft (nil = Standard-Raum, für ältere Bibliotheken).
    var roomID: UUID?
    /// Von Virtual im Raum gefunden (Startmenü-Verknüpfung) statt von Hand hinzugefügt.
    var detected: Bool?

    init(name: String, path: String, bookmark: Data?, roomID: UUID?, detected: Bool = false) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.roomID = roomID
        self.detected = detected
    }

    var url: URL { URL(fileURLWithPath: path) }

    var room: Room { RoomStore.shared.room(id: roomID) }

    /// Das Windows-Icon des Programms (aus der .exe bzw. dem Ziel der Verknüpfung).
    var icon: NSImage { WindowsIcon.icon(for: self) }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Verwaltet die Programmliste und speichert sie als JSON unter ~/WinMac_Virtual/library.json.
final class Library {
    static let shared = Library()
    static let supportedExtensions: Set<String> = ["exe", "msi", "lnk"]

    private(set) var programs: [Program] = []

    private var storeURL: URL {
        Settings.shared.root.appendingPathComponent("library.json")
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([Program].self, from: data) else {
            programs = []
            return
        }
        programs = list
        sort()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(programs) {
            try? FileManager.default.createDirectory(at: Settings.shared.root,
                                                     withIntermediateDirectories: true)
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func sort() {
        programs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static let didChange = Notification.Name("WinMacVirtual.library.didChange")

    func programs(in room: Room) -> [Program] {
        programs.filter { RoomStore.shared.room(id: $0.roomID).id == room.id }
    }

    private func changed() {
        sort()
        save()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Fügt eine .exe/.msi einem Raum hinzu (keine Duplikate nach Pfad und Raum).
    @discardableResult
    func add(url: URL, to room: Room) -> Program? {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        let url = url.standardizedFileURL
        if let existing = programs.first(where: { $0.path == url.path && $0.room.id == room.id }) { return existing }

        let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        let name = url.deletingPathExtension().lastPathComponent
        let program = Program(name: name, path: url.path, bookmark: bookmark, roomID: room.id)
        programs.append(program)
        changed()
        return program
    }

    /// Gleicht die gefundenen Verknüpfungen eines Raums ab; gibt die neuen Programme zurück.
    @discardableResult
    func syncDetected(_ found: [(name: String, path: String)], in room: Room) -> [Program] {
        let foundPaths = Set(found.map(\.path))
        let before = programs.count
        programs.removeAll { $0.detected == true && $0.room.id == room.id && !foundPaths.contains($0.path) }
        var added: [Program] = []
        for item in found where !programs.contains(where: { $0.path == item.path && $0.room.id == room.id }) {
            let program = Program(name: item.name, path: item.path, bookmark: nil, roomID: room.id, detected: true)
            programs.append(program)
            added.append(program)
        }
        if !added.isEmpty || programs.count != before + added.count { changed() }
        return added
    }

    func remove(_ program: Program) {
        programs.removeAll { $0.id == program.id }
        changed()
    }

    func removeAll(inRoom roomID: UUID) {
        programs.removeAll { $0.roomID == roomID }
        changed()
    }

    func rename(_ program: Program, to newName: String) {
        program.name = newName.isEmpty ? program.name : newName
        changed()
    }
}
