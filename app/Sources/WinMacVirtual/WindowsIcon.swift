import AppKit

/// Liest die Icons von Windows-Programmen: aus den Ressourcen einer .exe (PE-Format) und
/// über das Ziel einer Verknüpfung (.lnk). Ergebnisse werden pro Pfad zwischengespeichert.
enum WindowsIcon {
    private static var cache: [String: NSImage] = [:]

    static func icon(for program: Program) -> NSImage {
        if let cached = cache[program.path] { return cached }
        var image: NSImage?
        let url = URL(fileURLWithPath: program.path)
        switch url.pathExtension.lowercased() {
        case "exe":
            image = fromExecutable(url)
        case "lnk":
            if let target = shortcutTarget(url), let unix = unixPath(target, in: program.room) {
                image = fromExecutable(unix)
            }
        default:
            break
        }
        let result = image ?? fallback(for: url)
        cache[program.path] = result
        return result
    }

    private static func fallback(for url: URL) -> NSImage {
        if url.pathExtension.lowercased() == "msi",
           let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil) {
            return symbol
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSWorkspace.shared.icon(for: .application)
    }

    // MARK: - Verknüpfungen (Shell Link, MS-SHLLINK)

    /// Windows-Pfad des Ziels einer .lnk-Datei, z. B. „C:\\Program Files\\Steam\\steam.exe“.
    static func shortcutTarget(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count > 0x4C, data.u32(0) == 0x4C else { return nil }
        let flags = data.u32(0x14)
        var offset = 0x4C
        if flags & 0x1 != 0 { offset += 2 + Int(data.u16(offset)) }          // LinkTargetIDList
        guard flags & 0x2 != 0, offset + 0x1C <= data.count else { return nil } // LinkInfo
        let headerSize = Int(data.u32(offset + 4))
        let infoFlags = data.u32(offset + 8)
        guard infoFlags & 0x1 != 0 else { return nil }                          // VolumeIDAndLocalBasePath
        if headerSize >= 0x24, offset + 0x20 <= data.count {
            let unicodeOffset = Int(data.u32(offset + 0x1C))
            if unicodeOffset > 0, let path = data.utf16String(at: offset + unicodeOffset) { return path }
        }
        return data.cString(at: offset + Int(data.u32(offset + 0x10)))
    }

    /// „C:\\…“ im Raum → Pfad auf dem Mac (C: ist drive_c, Z: das Mac-Dateisystem).
    static func unixPath(_ windowsPath: String, in room: Room) -> URL? {
        let parts = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard parts.count >= 3, parts.dropFirst().first == ":" else { return nil }
        let rest = String(parts.dropFirst(3))
        switch parts.first?.lowercased() {
        case "c": return room.driveC.appendingPathComponent(rest)
        case "z": return URL(fileURLWithPath: "/" + rest)
        default:
            let link = room.prefixURL.appendingPathComponent("dosdevices/\(parts.first!.lowercased()):")
            return link.resolvingSymlinksInPath().appendingPathComponent(rest)
        }
    }

    // MARK: - Icons aus PE-Ressourcen

    private static func fromExecutable(_ url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), let pe = PEResources(data) else { return nil }
        // RT_GROUP_ICON (14) beschreibt die Größen, die Bilder selbst sind RT_ICON (3).
        guard let group = pe.firstResource(type: 14), group.count >= 6 else { return nil }
        let count = Int(group.u16(4))
        var best: (id: Int, size: Int, bits: Int)?
        for i in 0..<count where 6 + i * 14 + 14 <= group.count {
            let entry = 6 + i * 14
            let width = Int(group[group.startIndex + entry]) == 0 ? 256 : Int(group[group.startIndex + entry])
            let bits = Int(group.u16(entry + 6))
            let id = Int(group.u16(entry + 12))
            if best == nil || width > best!.size || (width == best!.size && bits > best!.bits) {
                best = (id, width, bits)
            }
        }
        guard let choice = best, let bitmap = pe.resource(type: 3, id: choice.id) else { return nil }
        if bitmap.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return NSImage(data: bitmap) }

        // Eine einzelne DIB als .ico verpacken, das NSImage lesen kann.
        var ico = Data([0, 0, 1, 0, 1, 0])
        let size = choice.size >= 256 ? 0 : UInt8(choice.size)
        ico.append(contentsOf: [size, size, 0, 0, 1, 0])
        ico.append(contentsOf: withUnsafeBytes(of: UInt16(choice.bits).littleEndian, Array.init))
        ico.append(contentsOf: withUnsafeBytes(of: UInt32(bitmap.count).littleEndian, Array.init))
        ico.append(contentsOf: withUnsafeBytes(of: UInt32(22).littleEndian, Array.init))
        ico.append(bitmap)
        return NSImage(data: ico)
    }
}

/// Minimaler Leser für den Ressourcenbaum einer PE-Datei (.exe/.dll).
private struct PEResources {
    let data: Data
    let rootOffset: Int
    let rootRVA: Int
    let sections: [(rva: Int, size: Int, offset: Int)]

    init?(_ data: Data) {
        self.data = data
        guard data.count > 0x40, data.u16(0) == 0x5A4D else { return nil }   // "MZ"
        let pe = Int(data.u32(0x3C))
        guard pe + 24 < data.count, data.u32(pe) == 0x4550 else { return nil } // "PE\0\0"
        let sectionCount = Int(data.u16(pe + 6))
        let optionalSize = Int(data.u16(pe + 20))
        let optional = pe + 24
        let magic = data.u16(optional)
        let directories = optional + (magic == 0x20B ? 112 : 96)
        guard directories + 24 <= data.count else { return nil }
        let resourceRVA = Int(data.u32(directories + 16))                     // Verzeichnis 2: Ressourcen
        guard resourceRVA != 0 else { return nil }
        var list: [(Int, Int, Int)] = []
        let table = optional + optionalSize
        for i in 0..<sectionCount {
            let s = table + i * 40
            guard s + 40 <= data.count else { break }
            list.append((Int(data.u32(s + 12)), max(Int(data.u32(s + 8)), Int(data.u32(s + 16))), Int(data.u32(s + 20))))
        }
        sections = list
        rootRVA = resourceRVA
        guard let root = PEResources.offset(of: resourceRVA, in: list) else { return nil }
        rootOffset = root
    }

    private static func offset(of rva: Int, in sections: [(rva: Int, size: Int, offset: Int)]) -> Int? {
        for s in sections where rva >= s.rva && rva < s.rva + s.size { return rva - s.rva + s.offset }
        return nil
    }

    /// Einträge eines Ressourcenverzeichnisses: (Id, Ziel, ist Unterverzeichnis).
    private func entries(at directory: Int) -> [(id: Int, target: Int, isDirectory: Bool)] {
        guard directory + 16 <= data.count else { return [] }
        let count = Int(data.u16(directory + 12)) + Int(data.u16(directory + 14))
        return (0..<count).compactMap { i in
            let e = directory + 16 + i * 8
            guard e + 8 <= data.count else { return nil }
            let target = data.u32(e + 4)
            return (Int(data.u32(e)), rootOffset + Int(target & 0x7FFF_FFFF), target & 0x8000_0000 != 0)
        }
    }

    private func leaf(_ directory: Int) -> Data? {
        // Unterhalb des Namens kommt noch die Sprachebene; die erste genügt.
        var node = directory
        for _ in 0..<2 {
            guard let first = entries(at: node).first else { return nil }
            if !first.isDirectory {
                guard first.target + 8 <= data.count, let start = PEResources.offset(of: Int(data.u32(first.target)), in: sections) else { return nil }
                let size = Int(data.u32(first.target + 4))
                guard start + size <= data.count else { return nil }
                return data.subdata(in: start..<start + size)
            }
            node = first.target
        }
        return nil
    }

    func firstResource(type: Int) -> Data? {
        guard let typeDir = entries(at: rootOffset).first(where: { $0.id == type && $0.isDirectory }),
              let named = entries(at: typeDir.target).first(where: { $0.isDirectory }) else { return nil }
        return leaf(named.target)
    }

    func resource(type: Int, id: Int) -> Data? {
        guard let typeDir = entries(at: rootOffset).first(where: { $0.id == type && $0.isDirectory }),
              let entry = entries(at: typeDir.target).first(where: { $0.id == id && $0.isDirectory }) else { return nil }
        return leaf(entry.target)
    }
}

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }

    func cString(at offset: Int) -> String? {
        guard offset >= 0, offset < count else { return nil }
        let end = self[(startIndex + offset)...].firstIndex(of: 0) ?? endIndex
        return String(data: self[(startIndex + offset)..<end], encoding: .windowsCP1252)
    }

    func utf16String(at offset: Int) -> String? {
        guard offset >= 0, offset < count else { return nil }
        var units: [UInt16] = []
        var i = offset
        while i + 2 <= count, case let u = u16(i), u != 0 { units.append(u); i += 2 }
        return units.isEmpty ? nil : String(utf16CodeUnits: units, count: units.count)
    }
}
