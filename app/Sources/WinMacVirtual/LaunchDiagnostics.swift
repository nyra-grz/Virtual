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

    static func message(status: Int32, output: String) -> String {
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
        if lower.contains("bad exe format") || lower.contains("c000007b") {
            return "Dieses Programm oder eine seiner Komponenten hat ein nicht unterstütztes Dateiformat. Virtual unterstützt Windows-Programme für x86 und x64; verwende den passenden vollständigen Installer."
        }
        return "Das Windows-Programm wurde mit Status \(status) beendet. Das Protokoll wurde gespeichert. Du kannst die Installation im Raum erneut ausführen; bleibt der Fehler bestehen, benötigt die App möglicherweise noch nicht unterstützte Windows-Funktionen."
    }
}
