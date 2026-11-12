import Foundation

/// File operations are independent of the UI. Originals are never removed here.
enum ProgramImport {
    struct Candidate {
        let source: URL
        let executables: [URL]
        var name: String { source.lastPathComponent }
    }
    struct Scan {
        var candidates: [Candidate] = []
        var warnings: [String] = []
    }
    struct Copy {
        let source: URL
        let destination: URL
        let executables: [URL]
    }
    enum Failure: LocalizedError {
        case cancelled, invalid(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Import abgebrochen. Die Originale bleiben erhalten."
            case .invalid(let reason): return reason
            }
        }
    }
    private static let extensions: Set<String> = ["exe", "msi"]
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let a = parent.standardizedFileURL.path, b = child.standardizedFileURL.path
        return a == b || b.hasPrefix(a == "/" ? a : a + "/")
    }

    /// Group by the first folder below a search root, keeping adjacent DLLs and data together.
    static func scan(roots: [URL], excluding: [URL], cancelled: () -> Bool = { false }) throws -> Scan {
        var result = Scan()
        let roots = roots.map { $0.standardizedFileURL }.sorted { $0.path.count < $1.path.count }
        var visited: [URL] = []
        for root in roots {
            if cancelled() { throw Failure.cancelled }
            guard !visited.contains(where: { contains($0, root) }) else { continue }
            visited.append(root)
            // Reject aliases into Virtual as well as explicitly chosen Virtual folders.
            if excluding.contains(where: { contains($0.resolvingSymlinksInPath(), root.resolvingSymlinksInPath()) }) {
                result.warnings.append("\(root.path): gehört bereits zu Virtual.")
                continue
            }
            let values = try root.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true, values.isPackage != true else {
                result.warnings.append("\(root.path): bitte einen normalen Ordner wählen.")
                continue
            }
            var groups: [URL: [URL]] = [:]
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
                    result.warnings.append("\(url.path): \(error.localizedDescription)")
                    return true
                }) else { throw Failure.invalid("„\(root.path)“ konnte nicht durchsucht werden.") }
            for case let foundURL as URL in walker {
                let url = foundURL.standardizedFileURL
                if cancelled() { throw Failure.cancelled }
                if excluding.contains(where: { contains($0.resolvingSymlinksInPath(), url.resolvingSymlinksInPath()) }) {
                    walker.skipDescendants(); continue
                }
                do {
                    let v = try url.resourceValues(forKeys: keys)
                    if v.isSymbolicLink == true { walker.skipDescendants(); continue }
                    guard v.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) else { continue }
                    let relative = String(url.path.dropFirst(root.path.count + 1))
                    let first = relative.split(separator: "/")[0]
                    let group = relative.contains("/") ? root.appendingPathComponent(String(first)) : url
                    // Never copy an ancestor of an excluded runtime/prefix, either.
                    guard !excluding.contains(where: { contains(group, $0) }) else { continue }
                    groups[group, default: []].append(url)
                } catch { result.warnings.append("\(url.path): \(error.localizedDescription)") }
            }
            result.candidates += groups.map { Candidate(source: $0.key, executables: $0.value.sorted { $0.path < $1.path }) }
        }
        result.candidates.sort { $0.source.path.localizedStandardCompare($1.source.path) == .orderedAscending }
        return result
    }

    private struct Entry: Equatable {
        let path: String
        let directory: Bool
        let size: UInt64
        let modified: Date?
    }
    private static func inventory(_ source: URL, cancelled: () -> Bool) throws -> [Entry] {
        var entries: [Entry] = []
        func visit(_ url: URL, relative: String) throws {
            if cancelled() { throw Failure.cancelled }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attrs[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else {
                throw Failure.invalid("„\(url.path)“ ist ein Link oder eine besondere Datei. Bitte einen Ordner ohne solche Dateien wählen.")
            }
            let directory = type == .typeDirectory
            entries.append(Entry(path: relative, directory: directory,
                                 size: directory ? 0 : (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                                 modified: directory ? nil : attrs[.modificationDate] as? Date))
            if directory {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent)
                }
            }
        }
        try visit(source, relative: "")
        return entries.sorted { $0.path < $1.path }
    }

    /// Each import gets its own folder; existing files can never be overwritten.
    static func copy(_ candidates: [Candidate], to driveC: URL, cancelled: () -> Bool = { false },
                     progress: (Int, Int) -> Void = { _, _ in }) throws -> [Copy] {
        let fm = FileManager.default
        let base = driveC.appendingPathComponent("Virtual Imports")
        guard base.resolvingSymlinksInPath().standardizedFileURL == driveC.resolvingSymlinksInPath().appendingPathComponent("Virtual Imports").standardizedFileURL,
              !candidates.contains(where: { contains($0.source, base) || contains(base, $0.source) }) else {
            throw Failure.invalid("Importquelle und Ziel dürfen sich nicht überschneiden oder über Links umgeleitet sein.")
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var created: [URL] = []
        var copies: [Copy] = []
        do {
            for (index, candidate) in candidates.enumerated() {
                if cancelled() { throw Failure.cancelled }
                progress(index, candidates.count)
                let before = try inventory(candidate.source, cancelled: cancelled)
                guard !candidate.executables.isEmpty else { throw Failure.invalid("Keine Programme in „\(candidate.name)“.") }
                let container = base.appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: container, withIntermediateDirectories: false)
                created.append(container)
                let destination = container.appendingPathComponent(candidate.name)
                for entry in before {
                    if cancelled() { throw Failure.cancelled }
                    let from = entry.path.isEmpty ? candidate.source : candidate.source.appendingPathComponent(entry.path)
                    let to = entry.path.isEmpty ? destination : destination.appendingPathComponent(entry.path)
                    if entry.directory { try fm.createDirectory(at: to, withIntermediateDirectories: true) }
                    else {
                        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.copyItem(at: from, to: to)
                        guard fm.contentsEqual(atPath: from.path, andPath: to.path) else {
                            throw Failure.invalid("Die Kopie von „\(from.path)“ stimmt nicht mit dem Original überein.")
                        }
                    }
                }
                guard try inventory(candidate.source, cancelled: cancelled) == before else {
                    throw Failure.invalid("„\(candidate.name)“ wurde während des Kopierens geändert. Bitte erneut durchsuchen.")
                }
                let executables = try candidate.executables.map { exe -> URL in
                    guard contains(candidate.source, exe) else { throw Failure.invalid("Ungültiger Programmpfad.") }
                    let relative = String(exe.path.dropFirst(candidate.source.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let target = relative.isEmpty ? destination : destination.appendingPathComponent(relative)
                    guard (try target.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                        throw Failure.invalid("„\(exe.path)“ fehlt in der Kopie. Bitte erneut durchsuchen.")
                    }
                    return target
                }
                copies.append(Copy(source: candidate.source, destination: container, executables: executables))
            }
            if cancelled() { throw Failure.cancelled }
            return copies
        } catch {
            var cleanupFailures: [String] = []
            for folder in created {
                do { try fm.removeItem(at: folder) }
                catch { cleanupFailures.append("\(folder.path): \(error.localizedDescription)") }
            }
            if !cleanupFailures.isEmpty {
                throw Failure.invalid("\(error.localizedDescription) Unvollständige Kopien konnten nicht entfernt werden: \(cleanupFailures.joined(separator: "; "))")
            }
            throw error
        }
    }

    static func discard(_ copies: [Copy]) throws {
        for copy in copies { try FileManager.default.removeItem(at: copy.destination) }
    }
}
