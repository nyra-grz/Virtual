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
    static let didFail = Notification.Name("WinMacVirtual.launcher.didFail")

    struct Running {
        let process: Process
        let logURL: URL
        let stopRequest: URL?
    }

    /// Laufende Prozesse nach Programm-ID.
    private var running: [UUID: Running] = [:]
    private var preparing: [UUID: Program] = [:]
    private var pendingTools: [UUID: UUID] = [:]
    private var stopping: Set<UUID> = []
    private var stopRequested: Set<UUID> = []
    private var repaired: Set<UUID> = []

    func isRunning(_ program: Program) -> Bool { running[program.id] != nil || preparing[program.id] != nil }
    func isPreparing(_ program: Program) -> Bool { preparing[program.id] != nil }

    /// Läuft gerade irgendein Windows-Programm?
    var hasRunning: Bool { !running.isEmpty || !tools.isEmpty || !preparing.isEmpty || !pendingTools.isEmpty || PrefixSetup.hasRunning }

    private var recentLogs: [UUID: URL] = [:]
    private var processRooms: [UUID: UUID] = [:]

    func hasRunningProcesses(in room: Room) -> Bool { processRooms.values.contains(room.id) }
    func hasRunning(in room: Room) -> Bool {
        hasRunningProcesses(in: room) || preparing.values.contains { $0.room.id == room.id } || pendingTools.values.contains(room.id)
    }

    /// Namen aller laufenden Programme und Werkzeuge, z. B. für die Rückfrage beim Beenden.
    var runningTitles: [String] {
        let names = running.keys.compactMap { id in Library.shared.programs.first { $0.id == id }?.name }
        return (names + preparing.values.map { $0.name + " (wird vorbereitet)" } + toolTitles.values).sorted()
    }
    func logURL(for program: Program) -> URL? { running[program.id]?.logURL ?? recentLogs[program.id] }

    /// Startet ein Programm in seinem Raum. Wirft bei fehlender Runtime/Datei.
    func launch(_ program: Program) throws {
        guard !Updater.shared.isInstalling else { throw LaunchError.updateInProgress }
        guard Settings.shared.runtimeIsInstalled else {
            throw LaunchError.runtimeMissing
        }
        guard program.exists else {
            throw LaunchError.fileMissing(program.path)
        }
        if isRunning(program) { return }
        repaired.remove(program.id)
        // Liste neu aufbauen, falls ein Update neue .exe in den Programmordner gelegt hat.
        if program.stayActive == true { StayActive.update(program.room) }

        preparing[program.id] = program
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        PrefixSetup.prepare(program) { [self] error in
            guard preparing.removeValue(forKey: program.id) != nil else { return }
            do {
                if let error { throw error }
                guard program.exists else { throw LaunchError.fileMissing(program.path) }
                try launchPrepared(program)
            } catch { reportFailure(error, id: program.id, title: program.name) }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private func launchPrepared(_ program: Program) throws {
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
        let launch = try start(arguments, in: room, title: program.name, id: programID,
                               directory: program.url.deletingLastPathComponent(), trackChildren: true,
                               manageClose: true) { [weak self] status in
            guard let self else { return }
            self.running[programID] = nil
            self.stopRequested.remove(programID)
            let stopped = self.stopping.remove(programID) != nil
            let isMSI = program.url.pathExtension.lowercased() == "msi"
            if !LaunchDiagnostics.installerSucceeded(status: status, isMSI: isMSI), !stopped, !(isMSI && (status == 1602 || status == 66)) {
                self.repairOrReport(status, program: program)
            }
        }
        recentLogs[programID] = launch.logURL
        running[programID] = launch
        NotificationCenter.default.post(name: Launcher.didChange, object: nil)
    }

    /// Startet ein Windows-Werkzeug (Explorer, Eingabeaufforderung, Installer …) in einem Raum.
    func runTool(_ arguments: [String], in room: Room, title: String, directory: URL? = nil,
                 trackChildren: Bool = false, manageClose: Bool = false) throws {
        guard !Updater.shared.isInstalling else { throw LaunchError.updateInProgress }
        guard Settings.shared.runtimeIsInstalled else { throw LaunchError.runtimeMissing }
        let id = UUID()
        pendingTools[id] = room.id
        toolTitles[id] = title
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        PrefixSetup.prepare(room) { [self] error in
            guard pendingTools.removeValue(forKey: id) != nil else { return }
            do {
                if let error { throw error }
                let launch = try start(arguments, in: room, title: title, id: id,
                                       directory: directory, trackChildren: trackChildren,
                                       manageClose: manageClose) { [weak self] status in
                    guard let self else { return }
                    self.tools[id] = nil
                    self.toolTitles[id] = nil
                    let stopped = self.stopping.remove(id) != nil
                    if status != 0, !stopped { self.reportExit(status, id: id, title: title) }
                }
                recentLogs[id] = launch.logURL
                tools[id] = launch.process
            } catch {
                toolTitles[id] = nil
                reportFailure(error, id: id, title: title)
            }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// Werkzeuge, die gerade laufen (hält die Process-Objekte am Leben).
    private var tools: [UUID: Process] = [:]
    private var toolTitles: [UUID: String] = [:]

    /// Beendet Wine in diesen Räumen vollständig – Programme, Werkzeuge und Hintergrunddienste
    /// (`wineserver -k`, dann `-w`). Startet nichts neu, wo nichts läuft. `completion` kommt auf dem
    /// Main-Thread, spätestens nach `timeout` Sekunden, mit den Räumen, deren Ende nicht bestätigt
    /// ist (leer = alles beendet). `-k` eskaliert selbst nach etwa 10 s zu SIGKILL.
    func stopAll(in rooms: [Room], timeout: TimeInterval = 15, completion: (([Room]) -> Void)? = nil) {
        let ids = Set(rooms.map(\.id))
        preparing = preparing.filter { !ids.contains($0.value.room.id) }
        for (id, roomID) in pendingTools where ids.contains(roomID) { pendingTools[id] = nil; toolTitles[id] = nil }
        stopping.formUnion(processRooms.filter { ids.contains($0.value) }.keys)
        for room in rooms { PrefixSetup.current(in: room)?.cancel() }
        let server = Settings.shared.virtualServer
        let deadline = Date() + timeout
        // Ein abgebrochenes Einrichtungsskript kann beim Aufräumen noch Wine starten: erst danach -k.
        Self.wait(until: deadline, for: { rooms.allSatisfy { PrefixSetup.current(in: $0) == nil } }) { [self] in
            let targets = rooms.filter { FileManager.default.fileExists(atPath: $0.prefixPath) }
                .map { ($0.id, RoomStore.shared.environment(for: $0)) }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let lock = NSLock()
                var failed = Set<UUID>()
                DispatchQueue.concurrentPerform(iterations: targets.count) { index in
                    guard !Self.stopServer(server, environment: targets[index].1, deadline: deadline) else { return }
                    lock.lock(); failed.insert(targets[index].0); lock.unlock()
                }
                DispatchQueue.main.async { [self] in
                    // Ohne Server enden auch die Programme; bestätigt erst, wenn ihre Prozesse weg sind.
                    Self.wait(until: deadline, for: { !self.processRooms.values.contains(where: ids.contains) }) { [self] in
                        completion?(rooms.filter {
                            failed.contains($0.id) || PrefixSetup.current(in: $0) != nil || processRooms.values.contains($0.id)
                        })
                    }
                }
            }
        }
    }

    /// Meldung für Räume, deren Ende `stopAll` nicht bestätigen konnte.
    static func stopFailureMessage(_ rooms: [Room]) -> String {
        let names = rooms.map { "„\($0.name)“" }.joined(separator: ", ")
        return "In \(names) ließ sich nicht bestätigen, dass alle Windows-Programme und Hintergrunddienste beendet sind; einige laufen möglicherweise weiter. Versuche es in einem Moment erneut mit „Alles beenden“."
    }

    /// `-k` beendet den Wine-Server des Raums (Status 1 heißt nur: es lief keiner), `-w` bestätigt,
    /// dass er wirklich weg ist. Ein fehlender Server lässt keine Bestätigung zu.
    private static func stopServer(_ server: URL, environment: [String: String], deadline: Date) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: server.path),
              let status = run(server, ["-k"], environment: environment, until: deadline),
              status == 0 || status == 1 else { return false }
        return run(server, ["-w"], environment: environment, until: deadline) == 0
    }

    /// Wartet auf einen Hilfsbefehl; nil, wenn er nicht startet oder die Frist überschreitet
    /// (dann wird er beendet, damit kein hängendes `-w` zurückbleibt).
    private static func run(_ executable: URL, _ arguments: [String], environment: [String: String], until deadline: Date) -> Int32? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        guard ended.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }

    /// Prüft `condition` auf dem Main-Thread alle 0,1 s, bis sie gilt oder die Frist abläuft.
    private static func wait(until deadline: Date, for condition: @escaping () -> Bool, then done: @escaping () -> Void) {
        if condition() || Date() >= deadline { done(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { wait(until: deadline, for: condition, then: done) }
    }

    private func start(_ arguments: [String], in room: Room, title: String, id: UUID, directory: URL? = nil,
                       trackChildren: Bool = false, manageClose: Bool = false,
                       ended: @escaping (Int32) -> Void) throws -> Running {
        let settings = Settings.shared
        try FileManager.default.createDirectory(at: settings.logsPath, withIntermediateDirectories: true)
        let helper = trackChildren ? Bundle.main.url(forResource: "program-runner", withExtension: "exe") : nil
        var environment = RoomStore.shared.environment(for: room)
        let requests = room.driveC.appendingPathComponent(".virtual", isDirectory: true)
            .appendingPathComponent("close", isDirectory: true)
        let token = UUID().uuidString
        let stopRequest = manageClose && helper != nil ? requests.appendingPathComponent(token + ".stop") : nil
        let windowRequest = stopRequest.map { $0.deletingPathExtension().appendingPathExtension("window") }
        if let stopRequest, let windowRequest {
            try FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
            environment["WINMAC_STOP_REQUEST"] = "C:\\.virtual\\close\\" + stopRequest.lastPathComponent
            environment["WINMAC_WINDOW_REQUEST"] = "C:\\.virtual\\close\\" + windowRequest.lastPathComponent
            environment["WINMAC_NATIVE_CLOSE_PATH"] = windowRequest.path
        }

        let stamp = Self.timestamp()
        let safeName = title.replacingOccurrences(of: "/", with: "_")
        let logURL = settings.logsPath.appendingPathComponent("\(safeName)-\(stamp)-\(id.uuidString.prefix(8)).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)

        let header = "Virtual · \(title)\nRaum: \(room.name)\nAufruf: \(arguments.joined(separator: " "))\nStart: \(Date())\nRuntime: \(settings.virtualBinary.path)\nPrefix: \(room.prefixPath)\n\n"
        handle.write(header.data(using: .utf8)!)

        let process = Process()
        process.executableURL = settings.virtualBinary
        if let helper {
            process.arguments = [helper.path] + arguments
        } else {
            process.arguments = arguments
        }
        process.environment = environment
        // Portable apps and installers often load files relative to their own folder.
        process.currentDirectoryURL = directory ?? room.driveC

        // Programme schreiben direkt in ihr Logfile, nicht in eine Pipe von Virtual: So laufen
        // sie (und ihr Log) weiter, wenn Virtual beendet wird. Die Live-Anzeige liest mit.
        process.standardOutput = handle
        process.standardError = handle

        let output = try ProgramOutput(log: handle, logURL: logURL, programID: id)
        let roomID = room.id

        process.terminationHandler = { proc in
            output.finish(status: proc.terminationStatus) {
                DispatchQueue.main.async {
                    for request in [stopRequest, windowRequest].compactMap({ $0 }) {
                        try? FileManager.default.removeItem(at: request)
                    }
                    self.processRooms[id] = nil
                    let status = LaunchDiagnostics.exitCode(status: proc.terminationStatus, output: Self.logTail(logURL))
                    ended(status)
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
            throw error
        }
        return Running(process: process, logURL: logURL, stopRequest: stopRequest)
    }

    /// Beendet ein laufendes Programm (sanft, dann hart).
    func stop(_ program: Program) {
        if preparing.removeValue(forKey: program.id) != nil {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
            return
        }
        guard let r = running[program.id], stopRequested.insert(program.id).inserted else { return }
        stopping.insert(program.id)
        var grace: TimeInterval = 0
        if let request = r.stopRequest, (try? Data().write(to: request, options: .atomic)) != nil {
            grace = 6
        }
        let terminate = {
            if r.process.isRunning { r.process.terminate() }
        }
        if grace > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: terminate) }
        else { terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + grace + 3) {
            if r.process.isRunning {
                kill(r.process.processIdentifier, SIGKILL)
            }
        }
    }

    private func reportFailure(_ error: Error, id: UUID, title: String) {
        NotificationCenter.default.post(name: Self.didFail, object: nil,
                                        userInfo: ["programID": id, "title": title, "message": error.localizedDescription])
    }

    /// Die eigentliche .exe hinter einem Programm (bei Verknüpfungen deren Ziel).
    private static func executableURL(_ program: Program) -> URL? {
        let url = URL(fileURLWithPath: program.path)
        guard url.pathExtension.lowercased() == "lnk" else { return url }
        return WindowsIcon.shortcutTarget(url).flatMap { WindowsIcon.unixPath($0, in: program.room) }
    }

    private func reportExit(_ status: Int32, id: UUID, title: String, program: Program? = nil) {
        let log = recentLogs[id]
        let text = log.map(Self.logTail) ?? ""
        let detail = LaunchDiagnostics.message(status: status, output: text,
                                               antiCheat: program.flatMap(Self.executableURL).flatMap(LaunchDiagnostics.kernelAntiCheat))
        reportFailure(PrefixSetup.SetupError(detail + (log.map { "\n\nProtokoll: \($0.path)" } ?? "")), id: id, title: title)
    }

    private func repairOrReport(_ status: Int32, program: Program) {
        let output = recentLogs[program.id].map(Self.logTail) ?? ""
        let missing = LaunchDiagnostics.missingComponents(output: output).filter {
            !FileManager.default.fileExists(atPath: program.room.prefixURL.appendingPathComponent(".virtual/components/\($0)").path)
        }
        guard !missing.isEmpty, repaired.insert(program.id).inserted else {
            reportExit(status, id: program.id, title: program.name, program: program)
            return
        }
        preparing[program.id] = program
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        PrefixSetup.repairDependencies(program, components: missing) { [self] error in
            guard preparing.removeValue(forKey: program.id) != nil else { return }
            do {
                if let error { throw error }
                guard program.exists else { throw LaunchError.fileMissing(program.path) }
                try launchPrepared(program)
            } catch { reportFailure(error, id: program.id, title: program.name) }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private static func logTail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: end > 32768 ? end - 32768 : 0)
        return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) } ?? ""
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
        case updateInProgress

        var errorDescription: String? {
            switch self {
            case .runtimeMissing:
                return "Die Windows-Engine fehlt noch. Virtual lädt sie über „Engine laden“ auf der Raum-Seite."
            case .fileMissing(let p):
                return "Datei nicht gefunden: \(p)"
            case .updateInProgress:
                return "Virtual wird gerade aktualisiert. Bitte warte, bis die App neu gestartet ist."
            }
        }
    }
}

/// Führt das Log eines gestarteten Programms. Das Programm schreibt selbst in die Datei
/// (stdout/stderr zeigen direkt darauf); hier wird nur für die Live-Anzeige mitgelesen und
/// am Ende der Footer angehängt. Mitlesen und Abschluss laufen auf einer seriellen Queue.
private final class ProgramOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WinMacVirtual.launcher.output")
    private let log: FileHandle
    private let reader: FileHandle
    private let programID: UUID
    private let source: DispatchSourceFileSystemObject

    init(log: FileHandle, logURL: URL, programID: UUID) throws {
        self.log = log
        reader = try FileHandle(forReadingFrom: logURL)
        self.programID = programID
        // Der Kopf steht schon im Log; mitgelesen wird nur, was das Programm schreibt.
        _ = try? reader.seekToEnd()
        let reader = self.reader
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: reader.fileDescriptor,
                                                           eventMask: [.extend, .write], queue: queue)
        // Der Handler hält self, bis die Quelle abgebrochen ist (finish/abort tun das immer).
        source.setEventHandler { self.drain() }
        source.setCancelHandler { try? reader.close() }
        source.resume()
    }

    /// Nach dem Prozessende: Neues noch mitlesen, dann den Footer schreiben. Von Wine
    /// gestartete Hintergrundprozesse (wineserver, services.exe) können danach weiter ins
    /// Log schreiben; das stört nicht, die Live-Anzeige endet hier.
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

    /// Liest, was seit dem letzten Mal ans Log angehängt wurde. Nur auf `queue` aufrufen.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(reader.fileDescriptor, &buffer, buffer.count)
            if n > 0 {
                announce(Data(buffer[0..<n]))
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return   // Dateiende: auf das nächste Anhängen warten
            }
        }
    }

    private func announce(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        let programID = self.programID
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Launcher.didLog, object: nil,
                                            userInfo: ["programID": programID, "line": text])
        }
    }
}
