import AppKit

/// Ein Windows-Programm in der Bibliothek.
final class Program: Codable {
    let id: UUID
    var name: String
    /// Pfad zur .exe/.msi als absoluter Dateipfad.
    var path: String
    /// Optionale Sicherheits-Bookmark-Daten, damit der Zugriff über Neustarts hinweg erhalten bleibt.
    var bookmark: Data?

    init(name: String, path: String, bookmark: Data?) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.bookmark = bookmark
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// Finder-Icon der Datei (oder ein generisches Programmsymbol).
    var icon: NSImage {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil)
            ?? NSWorkspace.shared.icon(for: .application)
    }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Verwaltet die Programmliste und speichert sie als JSON unter ~/WinMac_Virtual/library.json.
final class Library {
    static let shared = Library()

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

    /// Fügt eine Datei hinzu (keine Duplikate nach Pfad). Gibt das Programm zurück.
    @discardableResult
    func add(url: URL) -> Program? {
        let ext = url.pathExtension.lowercased()
        guard ext == "exe" || ext == "msi" else { return nil }
        if let existing = programs.first(where: { $0.path == url.path }) { return existing }

        let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                             includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        let name = url.deletingPathExtension().lastPathComponent
        let program = Program(name: name, path: url.path, bookmark: bookmark)
        programs.append(program)
        sort()
        save()
        return program
    }

    func remove(_ program: Program) {
        programs.removeAll { $0.id == program.id }
        save()
    }

    func rename(_ program: Program, to newName: String) {
        program.name = newName.isEmpty ? program.name : newName
        sort()
        save()
    }
}
