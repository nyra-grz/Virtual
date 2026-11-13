import AppKit

/// Erster Start einer schlanken App (Release-Download ohne Engine): Virtual fragt, ob es seine
/// Windows-Engine laden darf, stellt auf einem Apple-Chip vorher Rosetta sicher und zeigt den
/// Fortschritt. Danach richtet sich der Raum wie gewohnt beim ersten Programmstart ein.
final class EngineSetup {
    static let shared = EngineSetup()

    private(set) var isInstalling = false
    private var asking = false

    /// Eine Release-App kann ihre Engine aus dem GitHub-Release ihrer Version laden; Entwickler-
    /// Builds mit eigener Runtime (Umgebungsvariablen) nicht.
    var canDownload: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["WINMAC_ASSETS_ROOT"] == nil && env["WINMAC_RUNTIME"] == nil
            && Updater.isNewer(Updater.shared.currentVersion, than: "0")
    }

    func checkOnLaunch() {
        guard !Settings.shared.runtimeIsInstalled, canDownload else { return }
        offer()
    }

    /// Holt engine.json (für die Größe), fragt nach und lädt dann die Engine.
    func offer() {
        guard !isInstalling, !asking, canDownload else { return }
        asking = true
        let version = Updater.shared.currentVersion
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try EngineStore.manifest(for: version) }
            DispatchQueue.main.async {
                self.asking = false
                switch result {
                case .failure(let error):
                    Self.show("Windows-Engine nicht erreichbar",
                              "Virtual konnte die Engine für Version \(version) nicht bei GitHub finden (\(error.localizedDescription)). Bitte prüfe die Internetverbindung und versuche es über „Engine laden“ auf der Raum-Seite erneut.")
                case .success(let manifest):
                    self.confirm(manifest)
                }
            }
        }
    }

    private func confirm(_ manifest: Updater.EngineManifest) {
        let size = ByteCountFormatter.string(fromByteCount: manifest.size, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Virtual braucht noch seine Windows-Engine"
        alert.informativeText = "Damit Windows-Programme laufen, lädt Virtual die Engine einmalig von GitHub (\(size)) und prüft sie. Spätere Updates laden sie nur, wenn sie sich ändert."
        alert.addButton(withTitle: "Jetzt laden")
        alert.addButton(withTitle: "Später")
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ensureRosetta { [weak self] ready in
            if ready { self?.install(manifest) }
        }
    }

    private func install(_ manifest: Updater.EngineManifest) {
        isInstalling = true
        NotificationCenter.default.post(name: EngineStore.didChange, object: nil)
        let window = UpdateProgressWindow(title: "Windows-Engine wird geladen")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try EngineStore.install(manifest) { text, fraction in
                    DispatchQueue.main.async { window.update(text, fraction) }
                }
            }
            DispatchQueue.main.async {
                window.close()
                self.isInstalling = false
                NotificationCenter.default.post(name: EngineStore.didChange, object: nil)
                if case .failure(let error) = result {
                    Self.show("Windows-Engine nicht installiert", error.localizedDescription)
                }
            }
        }
    }

    /// `Virtual --install-engine`: die Engine dieser App-Version ohne Fenster laden (Skripte, Hilfe
    /// per Terminal). Mit `--force` auch, wenn schon eine Engine da ist.
    static func runFromCommandLine() -> Int32 {
        if Settings.shared.runtimeIsInstalled && !CommandLine.arguments.contains("--force") {
            print("Die Engine ist schon da: \(Settings.shared.assetsRoot.path)")
            return 0
        }
        do {
            let version = Updater.shared.currentVersion
            let manifest = try EngineStore.manifest(for: version)
            var last = ""
            try EngineStore.install(manifest) { text, fraction in
                let line = fraction.map { "\(text) \(Int($0 * 100)) %" } ?? text
                guard line != last, fraction == nil || Int((fraction ?? 0) * 100) % 10 == 0 else { return }
                last = line
                print(line)
            }
            print("Engine \(manifest.version.prefix(12)) installiert: \(EngineStore.folder.path)")
            if needsRosetta { print("Hinweis: Rosetta fehlt noch. Im Terminal: softwareupdate --install-rosetta") }
            return 0
        } catch {
            FileHandle.standardError.write("Engine nicht installiert: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }

    // MARK: - Rosetta

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// Die Engine besteht aus Intel-Programmen; auf einem Apple-Chip laufen sie nur mit Rosetta.
    static var needsRosetta: Bool {
        isAppleSilicon && !FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
    }

    /// Fehlt Rosetta, nach Rückfrage installieren; macOS fragt dabei nach dem Passwort.
    private func ensureRosetta(_ done: @escaping (Bool) -> Void) {
        guard Self.needsRosetta else { done(true); return }
        let alert = NSAlert()
        alert.messageText = "Virtual braucht Rosetta"
        alert.informativeText = "Die Windows-Engine läuft über Rosetta, Apples Übersetzer für Intel-Programme. macOS installiert Rosetta nach Eingabe deines Mac-Passworts; damit stimmst du Apples Lizenz für Rosetta zu."
        alert.addButton(withTitle: "Rosetta installieren")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { done(false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                guard !Self.needsRosetta else {
                    Self.show("Rosetta fehlt noch", "Rosetta wurde nicht installiert. Du kannst es auch im Terminal installieren: softwareupdate --install-rosetta")
                    done(false)
                    return
                }
                done(true)
            }
        }
    }

    private static func show(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
