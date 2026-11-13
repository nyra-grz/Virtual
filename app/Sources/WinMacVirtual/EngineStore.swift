import Foundation

/// Die Windows-Engine schlanker Apps (Release-Download ohne eingebaute Engine): Sie liegt unter
/// ~/Library/Application Support/Virtual/Engine und wird von Virtual selbst geladen, geprüft und
/// bei Updates ersetzt. Dort ist sie auch beschreibbar, wenn die App schreibgeschützt läuft (etwa
/// direkt aus „Downloads“ gestartet). Apps mit Engine im Bundle brauchen das nicht.
enum EngineStore {
    static let didChange = Notification.Name("WinMacVirtual.engine.didChange")

    static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["WINMAC_ENGINE_STORE"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Virtual/Engine", isDirectory: true)
    }

    static var version: String? { Updater.engineVersion(at: folder) }

    /// engine.json aus dem GitHub-Release dieser App-Version.
    static func manifest(for version: String) throws -> Updater.EngineManifest {
        let url = URL(string: "https://github.com/\(Updater.repo)/releases/download/v\(version)/engine.json")!
        return try JSONDecoder().decode(Updater.EngineManifest.self, from: Updater.fetch(URLRequest(url: url)))
    }

    /// Lädt die Engine, prüft Größe, SHA-256 und Version und ersetzt eine vorhandene erst danach.
    static func install(_ manifest: Updater.EngineManifest, into target: URL = folder,
                        progress: @escaping (String, Double?) -> Void = { _, _ in }) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Gleicher Ordner wie das Ziel: Der Austausch am Ende ist ein Umbenennen.
        let work = parent.appendingPathComponent(".engine-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let zip = work.appendingPathComponent("engine.zip")
        let size = ByteCountFormatter.string(fromByteCount: manifest.size, countStyle: .file)
        progress("Lade die Windows-Engine (\(size)) …", nil)
        try Updater.download(manifest.url, to: zip) { progress("Lade die Windows-Engine (\(size)) …", $0) }
        progress("Prüfe die Engine …", nil)
        try Updater.verify(zip, against: manifest)
        progress("Entpacke die Engine …", nil)
        try Updater.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        try? fm.removeItem(at: zip)

        let engine = work.appendingPathComponent("Engine", isDirectory: true)
        guard Updater.engineVersion(at: engine) == manifest.version,
              fm.isExecutableFile(atPath: engine.appendingPathComponent("runtime/bin/virtual").path)
        else { throw Updater.UpdateError.badEngine }
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: engine)
        } else {
            try fm.moveItem(at: engine, to: target)
        }
    }
}
