import Foundation

enum LaunchDiagnostics {
    static func missingComponents(output: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"Library\s+([^\s()]+\.dll)"#, options: .caseInsensitive)
        var libraries: [String] = []
        for line in output.components(separatedBy: .newlines) where line.contains("import_dll") && line.contains("not found") {
            if let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) { libraries.append(String(line[range])) }
        }
        return ExecutableRequirements.components(forLibraries: libraries)
    }

    static func exitCode(status: Int32, output: String) -> Int32 {
        for line in output.components(separatedBy: .newlines).reversed() where line.hasPrefix("VIRTUAL_EXIT_CODE=") {
            if let code = UInt32(line.dropFirst("VIRTUAL_EXIT_CODE=".count)) { return Int32(bitPattern: code) }
        }
        return status
    }

    /// https://learn.microsoft.com/en-us/windows/win32/msi/error-codes
    static func installerSucceeded(status: Int32, isMSI: Bool) -> Bool {
        status == 0 || status == 3010 || status == 1641 || (isMSI && (status == 194 || status == 105))
    }

    /// Anti-Cheat mit Windows-Kerneltreiber, erkannt an Treibern und Installern im Spielordner.
    private static let antiCheatMarkers: [String: String] = [
        "easyanticheat.sys": "Easy Anti-Cheat", "easyanticheat_eos.sys": "Easy Anti-Cheat",
        "easyanticheat_setup.exe": "Easy Anti-Cheat", "easyanticheat_eos_setup.exe": "Easy Anti-Cheat",
        "bedaisy.sys": "BattlEye", "beservice.exe": "BattlEye", "beservice_x64.exe": "BattlEye",
        "vgk.sys": "Riot Vanguard", "vgc.exe": "Riot Vanguard",
        "mhyprot2.sys": "mhyprot", "mhyprot3.sys": "mhyprot",
        "xhunter1.sys": "XIGNCODE3", "gameguard.des": "nProtect GameGuard", "faceit.sys": "FACEIT",
    ]

    /// Sucht im Ordner des Programms und bis zu zwei Ebenen darüber (Spiele liegen oft in
    /// Binaries/Win64 unter dem Spielordner), jeweils bis zu drei Ebenen tief.
    static func kernelAntiCheat(near program: URL) -> String? {
        let fm = FileManager.default
        var directory = program.deletingLastPathComponent()
        let stops: Set<String> = ["drive_c", "program files", "program files (x86)", "common", "users", "appdata", "local", "roaming"]
        for _ in 0..<3 {
            guard !stops.contains(directory.lastPathComponent.lowercased()) else { break }
            let base = directory.pathComponents.count
            if let walker = fm.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let url as URL in walker {
                    if url.pathComponents.count - base >= 3 { walker.skipDescendants() }
                    if let name = antiCheatMarkers[url.lastPathComponent.lowercased()] { return name }
                }
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    static func message(status: Int32, output: String, antiCheat: String? = nil) -> String {
        if let antiCheat {
            return "Dieses Spiel nutzt \(antiCheat) mit einem Windows-Kerneltreiber. Solche Anti-Cheat-Systeme laufen unter Wine grundsätzlich nicht – auch nicht in CrossOver oder Whisky. Einzelspieler- oder Offline-Modi ohne Anti-Cheat funktionieren manchmal."
        }
        let lower = output.lowercased()
        if lower.contains("wine mono is not installed") || lower.contains("failed to load the runtime") ||
           lower.contains("could not load file or assembly") {
            return "Die benötigte .NET-Laufzeit konnte nicht geladen werden. Öffne den Raum und wähle unter Windows-Werkzeuge „.NET Framework 4.8“, um sie in Virtual zu installieren."
        }
        if let missing = output.components(separatedBy: .newlines).first(where: {
            $0.lowercased().contains("import_dll") && $0.lowercased().contains("not found")
        }) {
            return "Eine benötigte Windows-Komponente fehlt:\n\(missing.trimmingCharacters(in: .whitespaces))\n\nInstalliere das Programm mit seinem vollständigen Windows-Installer im selben Raum. Bei einer portablen App muss der gesamte entpackte Ordner erhalten bleiben."
        }
        // Eine DLL des Programms leitet Funktionen an eine Windows-Systembibliothek weiter,
        // die Wine (noch) nicht hat, z. B. icuuc.dll → icu.dll.
        let forward = try! NSRegularExpression(pattern: #"find_forwarded_export .*?forward '([^'.]+)\."#)
        if let match = forward.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let range = Range(match.range(at: 1), in: output) {
            return "Dem Programm fehlt die Windows-Systembibliothek \(output[range]).dll, die Virtual noch nicht mitbringt. Das lässt sich nicht im Raum nachinstallieren; bitte melde das Programm, damit die Bibliothek ergänzt wird."
        }
        if lower.contains("bad exe format") || lower.contains("c000007b") {
            return "Dieses Programm oder eine seiner Komponenten hat ein nicht unterstütztes Dateiformat. Virtual unterstützt Windows-Programme für x86 und x64; verwende den passenden vollständigen Installer."
        }
        return "Das Windows-Programm wurde mit Status \(status) beendet. Das Protokoll wurde gespeichert. Du kannst die Installation im Raum erneut ausführen; bleibt der Fehler bestehen, benötigt die App möglicherweise noch nicht unterstützte Windows-Funktionen."
    }
}
