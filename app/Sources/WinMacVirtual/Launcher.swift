import AppKit

/// Startet Windows-Programme über die `virtual`-Runtime, führt pro Start ein Logfile
/// und verfolgt laufende Prozesse. Meldet Statusänderungen über NotificationCenter.
final class Launcher {
    static let shared = Launcher()

    static let didChange = Notification.Name("WinMacVirtual.launcher.didChange")
    /// userInfo: ["programID": UUID, "line": String] – eine neue Logzeile.
    static let didLog = Notification.Name("WinMacVirtual.launcher.didLog")
    /// userInfo: ["room": UUID] – ein Programm oder Werkzeug in diesem Raum ist beendet.
    static let didFinishInRoom = Notification.Name("WinMacVirtual.launcher.didFinishInRoom")

    struct Running {
        let process: Process
        let logURL: URL
    }

    /// Laufende Prozesse nach Programm-ID.
    private var running: [UUID: Running] = [:]

    func isRunning(_ program: Program) -> Bool { running[program.id] != nil }

    /// Läuft gerade irgendein Windows-Programm?
    var hasRunning: Bool { !running.isEmpty || !tools.isEmpty }

    private var recentLogs: [UUID: URL] = [:]
    private var processRooms: [UUID: UUID] = [:]

    func hasRunning(in room: Room) -> Bool { processRooms.values.contains(room.id) }
    func logURL(for program: Program) -> URL? { running[program.id]?.logURL ?? recentLogs[program.id] }

    /// Startet ein Programm in seinem Raum. Wirft bei fehlender Runtime/Datei.
    func launch(_ program: Program) throws {
        guard Settings.shared.runtimeIsInstalled else {
            throw LaunchError.runtimeMissing
        }
        guard program.exists else {
            throw LaunchError.fileMissing(program.path)
        }
        if isRunning(program) { return }

        let room = program.room
        let arguments: [String]
        switch URL(fileURLWithPath: program.path).pathExtension.lowercased() {
        case "msi":
            // Eine .msi ist kein Programm, sondern ein Paket für den Windows Installer.
            arguments = ["msiexec", "/i", Self.windowsPath(program.path, prefix: room.prefixURL)]
        case "lnk":
            // Verknüpfungen löst Windows selbst auf; /wait hält den Status, bis das Programm endet.
            arguments = ["start", "/wait", "/unix", program.path]
        default:
            arguments = [program.path]
        }

        let programID = program.id
        let (process, logURL) = try start(arguments, in: room, title: program.name, id: programID, trackChildren: true) { [weak self] in
            self?.running[programID] = nil
        }
        recentLogs[programID] = logURL
        running[programID] = Running(process: process, logURL: logURL)
        NotificationCenter.default.post(name: Launcher.didChange, object: nil)
    }

    /// Startet ein Windows-Werkzeug (Explorer, Eingabeaufforderung, Installer …) in einem Raum.
    func runTool(_ arguments: [String], in room: Room, title: String) throws {
        guard Settings.shared.runtimeIsInstalled else { throw LaunchError.runtimeMissing }
        let id = UUID()
        let (process, _) = try start(arguments, in: room, title: title, id: id) { [weak self] in
            self?.tools[id] = nil
        }
        tools[id] = process
    }

    /// Werkzeuge, die gerade laufen (hält die Process-Objekte am Leben).
    private var tools: [UUID: Process] = [:]

    private func start(_ arguments: [String], in room: Room, title: String, id: UUID,
                       trackChildren: Bool = false, ended: @escaping () -> Void) throws -> (Process, URL) {
        let settings = Settings.shared
        try FileManager.default.createDirectory(at: settings.logsPath, withIntermediateDirectories: true)

        let stamp = Self.timestamp()
        let safeName = title.replacingOccurrences(of: "/", with: "_")
        let logURL = settings.logsPath.appendingPathComponent("\(safeName)-\(stamp)-\(id.uuidString.prefix(8)).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)

        let header = "Virtual · \(title)\nRaum: \(room.name)\nAufruf: \(arguments.joined(separator: " "))\nStart: \(Date())\nRuntime: \(settings.virtualBinary.path)\nPrefix: \(room.prefixPath)\n\n"
        handle.write(header.data(using: .utf8)!)

        let process = Process()
        process.executableURL = settings.virtualBinary
        if trackChildren, let helper = Bundle.main.url(forResource: "program-runner", withExtension: "exe") {
            process.arguments = [helper.path] + arguments
        } else {
            process.arguments = arguments
        }
        process.environment = RoomStore.shared.environment(for: room)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let output = ProgramOutput(log: handle, reader: pipe.fileHandleForReading, programID: id)
        let roomID = room.id

        process.terminationHandler = { proc in
            output.finish(status: proc.terminationStatus) {
                DispatchQueue.main.async {
                    self.processRooms[id] = nil
                    ended()
                    NotificationCenter.default.post(name: Launcher.didChange, object: nil)
                    NotificationCenter.default.post(name: Launcher.didFinishInRoom, object: nil, userInfo: ["room": roomID])
                }
            }
        }

        do {
            try process.run()
            processRooms[id] = room.id
        } catch {
            // Ohne Start ruft Process den terminationHandler nie auf: selbst aufräumen.
            output.abort()
            try? pipe.fileHandleForWriting.close()
            throw error
        }
        return (process, logURL)
    }

    /// Beendet ein laufendes Programm (sanft, dann hart).
    func stop(_ program: Program) {
        guard let r = running[program.id] else { return }
        r.process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if r.process.isRunning {
                kill(r.process.processIdentifier, SIGKILL)
            }
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }

    /// Unix-Pfad → Windows-Pfad über die Laufwerke des Prefixes (dosdevices), wie `winepath -w`:
    /// Das Laufwerk mit dem längsten passenden Ziel gewinnt, meist Z: (→ /).
    static func windowsPath(_ path: String, prefix: URL) -> String {
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let devices = prefix.appendingPathComponent("dosdevices")
        var best: (drive: String, root: String)?
        for name in (try? FileManager.default.contentsOfDirectory(atPath: devices.path)) ?? [] {
            guard name.count == 2, name.hasSuffix(":") else { continue }   // c:, z: – nicht c:: oder com1
            let root = devices.appendingPathComponent(name).resolvingSymlinksInPath().path
            guard root == "/" || file == root || file.hasPrefix(root + "/") else { continue }
            if root.count > (best?.root.count ?? -1) { best = (name.uppercased(), root) }
        }
        guard let best else {
            // Kein Laufwerk deckt die Datei ab: Wines eigener Unix-Namensraum.
            return "\\\\?\\unix" + file.replacingOccurrences(of: "/", with: "\\")
        }
        let rest = best.root == "/" ? String(file.dropFirst()) : String(file.dropFirst(best.root.count + 1))
        return best.drive + "\\" + rest.replacingOccurrences(of: "/", with: "\\")
    }

    enum LaunchError: LocalizedError {
        case runtimeMissing
        case fileMissing(String)

        var errorDescription: String? {
            switch self {
            case .runtimeMissing:
                return "Keine Runtime gefunden. Bitte zuerst build-wine.sh oder make-runtime-from-brew.sh ausführen und in den Einstellungen den Runtime-Pfad prüfen."
            case .fileMissing(let p):
                return "Datei nicht gefunden: \(p)"
            }
        }
    }
}

/// Schreibt die Ausgabe eines gestarteten Programms ins Log. Lesen, Schreiben und Abschluss
/// laufen auf einer seriellen Queue: Was das Programm vor seinem Ende geschrieben hat, wird
/// vor dem Footer vollständig aus der Pipe geholt, und nach dem Footer kommt nichts mehr.
private final class ProgramOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WinMacVirtual.launcher.output")
    private let log: FileHandle
    private let reader: FileHandle
    private let programID: UUID
    private let source: DispatchSourceRead

    init(log: FileHandle, reader: FileHandle, programID: UUID) {
        self.log = log
        self.reader = reader
        self.programID = programID
        let fd = reader.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // Der Handler hält self, bis die Quelle abgebrochen ist (finish/abort tun das immer).
        source.setEventHandler { self.drain() }
        source.setCancelHandler { try? reader.close() }
        source.resume()
    }

    /// Nach dem Prozessende: Rest aus der Pipe holen, ohne auf EOF zu warten – von Wine
    /// gestartete Hintergrundprozesse (wineserver, services.exe) halten die Pipe oft weiter offen.
    func finish(status: Int32, then done: @escaping () -> Void) {
        queue.async {
            if !self.source.isCancelled {
                self.drain()
                self.source.cancel()
            }
            let footer = "\n\nBeendet: \(Date()) · Status \(status)\n"
            try? self.log.write(contentsOf: footer.data(using: .utf8)!)
            try? self.log.close()
            done()
        }
    }

    /// Start gescheitert: alles schließen, ohne Footer.
    func abort() {
        queue.sync {
            source.cancel()
            try? log.close()
        }
    }

    /// Liest, was gerade in der Pipe liegt (nicht blockierend). Nur auf `queue` aufrufen.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(reader.fileDescriptor, &buffer, buffer.count)
            if n > 0 {
                append(Data(buffer[0..<n]))
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                if n == 0 { source.cancel() }   // EOF: alle Schreiber haben die Pipe geschlossen
                return
            }
        }
    }

    private func append(_ data: Data) {
        try? log.write(contentsOf: data)
        guard let text = String(data: data, encoding: .utf8) else { return }
        let programID = self.programID
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Launcher.didLog, object: nil,
                                            userInfo: ["programID": programID, "line": text])
        }
    }
}
