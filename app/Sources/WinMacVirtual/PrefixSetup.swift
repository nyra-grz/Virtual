import AppKit

/// Legt beim Erststart die Windows-Umgebung an: virtualboot, Windows-Version setzen,
/// optional .NET. Läuft im Hintergrund und meldet Fortschritt zeilenweise.
final class PrefixSetup {

    static let didLog = Notification.Name("WinMacVirtual.prefix.didLog")
    static let didFinish = Notification.Name("WinMacVirtual.prefix.didFinish")

    private(set) var isRunning = false
    /// Hält den laufenden Prozess am Leben, bis er beendet ist.
    private var process: Process?

    /// Startet die Einrichtung über das Skript scripts/init-prefix.sh (liegt neben der Runtime-Wurzel).
    func run() {
        guard !isRunning else { return }
        isRunning = true

        let settings = Settings.shared
        let script = settings.root.appendingPathComponent("scripts/init-prefix.sh")

        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, settings.windowsVersion]

        var env = ProcessInfo.processInfo.environment
        env["WINMAC_ROOT"] = settings.root.path
        env["WINEPREFIX"] = settings.prefixPath.path
        env["WINMAC_RUNTIME"] = settings.runtimePath.path
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: PrefixSetup.didLog, object: nil,
                                                userInfo: ["line": text])
            }
        }

        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.isRunning = false
                if proc.terminationStatus == 0 { Settings.shared.didInitPrefix = true }
                NotificationCenter.default.post(name: PrefixSetup.didFinish, object: nil,
                                                userInfo: ["status": proc.terminationStatus])
            }
        }

        do {
            try process.run()
        } catch {
            isRunning = false
            NotificationCenter.default.post(name: PrefixSetup.didLog, object: nil,
                                            userInfo: ["line": "Fehler: \(error.localizedDescription)\n"])
            NotificationCenter.default.post(name: PrefixSetup.didFinish, object: nil,
                                            userInfo: ["status": Int32(-1)])
        }
    }
}
