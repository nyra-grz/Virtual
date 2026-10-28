import Foundation

/// Derives dependencies from the executable's real import table and .NET runtime
/// configuration. No application-name guesses and no downloads during inspection.
struct ExecutableRequirements {
    var components: [String] = []
    var needsDotNet48 = false

    static func inspect(_ url: URL, in room: Room) -> Self {
        var target = url
        if url.pathExtension.lowercased() == "lnk", let path = WindowsIcon.shortcutTarget(url),
           let resolved = WindowsIcon.unixPath(path, in: room) { target = resolved }
        guard target.pathExtension.lowercased() == "exe", let data = try? Data(contentsOf: target, options: .mappedIfSafe) else { return Self() }
        let image = PEImports(data: data)
        var result = Self()
        let arch = image.machine == 0x14c ? "x86" : "x64"
        let config = target.deletingPathExtension().appendingPathExtension("runtimeconfig.json")
        if let bytes = try? Data(contentsOf: config),
           let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
           let options = json["runtimeOptions"] as? [String: Any] {
            var frameworks = options["frameworks"] as? [[String: Any]] ?? []
            if let framework = options["framework"] as? [String: Any] { frameworks.append(framework) }
            for framework in frameworks {
                guard let name = framework["name"] as? String, let version = framework["version"] as? String,
                      let major = version.split(separator: ".").first.flatMap({ Int($0) }), (6...10).contains(major) else { continue }
                guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { continue }
                if name == "Microsoft.WindowsDesktop.App" { result.components.append("dotnetdesktop\(major)-\(arch)@\(version)") }
                else if name == "Microsoft.NETCore.App" { result.components.append("dotnet\(major)-\(arch)@\(version)") }
            }
        } else if image.hasCLR {
            result.needsDotNet48 = ["PresentationFramework", "System.Runtime.WindowsRuntime", "System.Xaml"].contains {
                data.range(of: Data($0.utf8)) != nil
            }
        }
        var libraries = image.names
        var pending = image.names.map { ($0, 0) }
        var visited = Set<String>()
        var inspectedLibraries = 0
        let folder = target.deletingLastPathComponent().resolvingSymlinksInPath()
        // System imports do not consume the local-DLL inspection budget. Large
        // programs commonly import 32+ system DLLs before their own Qt/plugin
        // library, which can be the only place a VC runtime dependency appears.
        while !pending.isEmpty && inspectedLibraries < 32 {
            let (name, depth) = pending.removeFirst()
            guard !name.contains("/"), !name.contains("\\"), !name.contains(":"), visited.insert(name.lowercased()).inserted else { continue }
            let sibling = folder.appendingPathComponent(name).resolvingSymlinksInPath()
            guard sibling.path.hasPrefix(folder.path + "/"), let bytes = try? Data(contentsOf: sibling, options: .mappedIfSafe) else { continue }
            inspectedLibraries += 1
            let imports = PEImports(data: bytes).names
            libraries.append(contentsOf: imports)
            if depth < 2 { pending.append(contentsOf: imports.map { ($0, depth + 1) }) }
        }
        result.components.append(contentsOf: components(forLibraries: libraries, in: folder))
        // XNA-Spiele (.NET) laden das Framework zur Laufzeit, nicht über die Import-Tabelle.
        if image.hasCLR, data.range(of: Data("Microsoft.Xna.Framework".utf8)) != nil { result.components.append("xna40") }
        result.components = Array(Set(result.components)).sorted()
        let selected = result.components
        // Desktop runtime packages include the corresponding base runtime.
        result.components.removeAll { component in
            component.hasPrefix("dotnet") && !component.hasPrefix("dotnetdesktop") &&
            selected.contains(component.replacingOccurrences(of: "dotnet", with: "dotnetdesktop"))
        }
        return result
    }

    static func components(forLibraries libraries: [String], in folder: URL? = nil) -> [String] {
        var result = Self()
        for name in libraries {
            let dll = name.lowercased()
            if dll.hasPrefix("vcruntime140") || dll.hasPrefix("msvcp140") || dll.hasPrefix("mfc140") { result.components.append("vcrun2026") }
            else if ["msvcr120.dll", "msvcp120.dll", "mfc120.dll"].contains(dll) { result.components.append("vcrun2013") }
            else if ["msvcr110.dll", "msvcp110.dll", "mfc110.dll"].contains(dll) { result.components.append("vcrun2012") }
            else if ["msvcr100.dll", "msvcp100.dll", "mfc100.dll"].contains(dll) { result.components.append("vcrun2010") }
            else if ["msvcr90.dll", "msvcp90.dll", "mfc90.dll", "mfc90u.dll"].contains(dll) { result.components.append("vcrun2008") }
            else if ["msvcr80.dll", "msvcp80.dll", "mfc80.dll", "mfc80u.dll"].contains(dll) { result.components.append("vcrun2005") }
            else if ["mfc42.dll", "mfc42u.dll"].contains(dll) { result.components.append("mfc42") }
            else if dll == "msvbvm60.dll" { result.components.append("vb6run") }
            else if dll == "d3dcompiler_47.dll" { result.components.append("d3dcompiler_47") }
            else if dll == "d3dcompiler_43.dll" { result.components.append("d3dcompiler_43") }
            else if dll.hasPrefix("d3dx9_") { result.components.append("d3dx9") }
            else if dll.hasPrefix("d3dx10_") || dll.hasPrefix("d3dx11_") { result.components.append(d3dxRecipe(dll)) }
            else if dll.hasPrefix("physxloader") || dll.hasPrefix("physxcore") || dll.hasPrefix("physxcooking") { result.components.append("physx") }
            else if dll == "msxml6.dll" { result.components.append("msxml6") }
            else if dll == "msxml4.dll" { result.components.append("msxml4") }
            else if dll == "openal32.dll" && !(folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("OpenAL32.dll").path) } ?? false) {
                result.components.append("openal")
            }
        }
        return Array(Set(result.components)).sorted()
    }

    /// Rezepte des gebündelten winetricks: eigene für d3dx10_43, d3dx11_42 und d3dx11_43;
    /// d3dx10_33…42 liefert nur „d3dx10“ (alle d3dx10-Fassungen). Unbekannte wie bisher → _43.
    private static func d3dxRecipe(_ dll: String) -> String {
        let name = dll.hasSuffix(".dll") ? String(dll.dropLast(4)) : dll
        if ["d3dx10_43", "d3dx11_42", "d3dx11_43"].contains(name) { return name }
        if name.hasPrefix("d3dx10_"), let version = Int(name.dropFirst(7)), (33...42).contains(version) { return "d3dx10" }
        return name.hasPrefix("d3dx10_") ? "d3dx10_43" : "d3dx11_43"
    }

    private struct PEImports {
        let data: Data
        private func word(_ offset: Int) -> UInt16 {
            guard offset >= 0, offset + 2 <= data.count else { return 0 }
            return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        private func dword(_ offset: Int) -> UInt32 { UInt32(word(offset)) | UInt32(word(offset + 2)) << 16 }
        private var pe: Int { Int(dword(0x3c)) }
        var machine: UInt16 { valid ? word(pe + 4) : 0 }
        private var valid: Bool { data.count >= 64 && word(0) == 0x5a4d && pe <= data.count - 24 && dword(pe) == 0x4550 }
        private var directory: Int { pe + 24 + (word(pe + 24) == 0x20b ? 112 : 96) }
        var hasCLR: Bool { valid && dword(directory + 14 * 8) != 0 }
        private func offset(_ rva: UInt32) -> Int? {
            let sections = pe + 24 + Int(word(pe + 20))
            for index in 0..<min(Int(word(pe + 6)), 96) {
                let section = sections + index * 40
                guard section + 40 <= data.count else { return nil }
                let base = dword(section + 12), length = max(dword(section + 8), dword(section + 16))
                if rva >= base && UInt64(rva) < UInt64(base) + UInt64(length) {
                    let file = UInt64(dword(section + 20)) + UInt64(rva - base)
                    return file < UInt64(data.count) ? Int(file) : nil
                }
            }
            return nil
        }
        var names: [String] {
            guard valid, let table = offset(dword(directory + 8)) else { return [] }
            var result: [String] = []
            for index in 0..<4096 {
                let descriptor = table + index * 20
                guard descriptor + 20 <= data.count, dword(descriptor + 12) != 0 else { break }
                guard let start = offset(dword(descriptor + 12)) else { continue }
                let end = min(data.count, start + 256)
                if let zero = data[start..<end].firstIndex(of: 0),
                   let name = String(data: data[start..<zero], encoding: .ascii) { result.append(name.lowercased()) }
            }
            return result
        }
    }
}
