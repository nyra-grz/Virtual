import AppKit

/// One preparation per room, shared by every launch entry point. A second app
/// waits for the same job instead of racing wineboot or changing DLLs underneath it.
final class PrefixSetup {
    enum Task: Equatable {
        case setup, dotnet48, components([String]), graphics(String)
        var script: String {
            switch self {
            case .setup: return "scripts/init-prefix.sh"
            case .dotnet48: return "scripts/setup-dotnet48.sh"
            case .components: return "scripts/setup-dependencies.sh"
            case .graphics: return "setup-graphics.sh"
            }
        }
    }
    static let didLog = Notification.Name("WinMacVirtual.prefix.didLog")
    static let didFinish = Notification.Name("WinMacVirtual.prefix.didFinish")
    static let didChange = Notification.Name("WinMacVirtual.prefix.didChange")
    private static var active: [UUID: PrefixSetup] = [:]
    private static var dependencyRequests: [UUID: [(program: Program, extra: [String], completion: (Error?) -> Void)]] = [:]
    private static var dependencyScheduled: Set<UUID> = []
    static var hasRunning: Bool { !active.isEmpty }
    static func current(in room: Room) -> PrefixSetup? { active[room.id] }

    private(set) var isRunning = false
    private var process: Process?
    private var completions: [(Error?) -> Void] = []
    private var output = ""
    private(set) var room: Room?
    private(set) var task: Task = .setup

    static func isPrepared(_ room: Room) -> Bool {
        room.isReady && (try? String(contentsOf: marker(in: room), encoding: .utf8)) == Settings.shared.preparationVersion
    }
    private static func marker(in room: Room) -> URL { room.prefixURL.appendingPathComponent(".virtual/prepared-version") }

    static func prepare(_ program: Program, completion: @escaping (Error?) -> Void) {
        prepare(program.room) { error in
            if let error { completion(error); return }
            prepareDependencies(program, completion: completion)
        }
    }

    private static func prepareDependencies(_ program: Program, completion: @escaping (Error?) -> Void) {
        let room = program.room
        dependencyRequests[room.id, default: []].append((program, [], completion))
        scheduleDependencies(room)
    }

    static func repairDependencies(_ program: Program, components: [String], completion: @escaping (Error?) -> Void) {
        dependencyRequests[program.room.id, default: []].append((program, components, completion))
        scheduleDependencies(program.room)
    }

    private static func scheduleDependencies(_ room: Room) {
        guard dependencyScheduled.insert(room.id).inserted else { return }
        DispatchQueue.main.async {
            dependencyScheduled.remove(room.id)
            runDependencies(room)
        }
    }

    private static func runDependencies(_ room: Room) {
        guard let requests = dependencyRequests[room.id], !requests.isEmpty else { return }
        if let job = active[room.id] {
            job.completions.append { error in
                if let error { finishDependencies(room, error: error) } else { scheduleDependencies(room) }
            }
            return
        }
        let requirements = requests.map { ExecutableRequirements.inspect($0.program.url, in: room) }
        let missing = Set(requirements.flatMap(\.components) + requests.flatMap(\.extra)).filter {
            !FileManager.default.fileExists(atPath: room.prefixURL.appendingPathComponent(".virtual/components/\($0)").path)
        }.sorted()
        let nativeDotNet = requirements.contains(where: \.needsDotNet48) && !room.hasDotNet48
        guard nativeDotNet || !missing.isEmpty else { finishDependencies(room, error: nil); return }
        guard !Launcher.shared.hasRunningProcesses(in: room) else {
            finishDependencies(room, error: SetupError("Bitte zuerst die anderen Programme in „\(room.name)“ beenden. Virtual installiert danach die benötigten Windows-Komponenten automatisch."))
            return
        }
        PrefixSetup().run(room, task: nativeDotNet ? .dotnet48 : .components(missing)) { error in
            if let error { finishDependencies(room, error: error) } else { scheduleDependencies(room) }
        }
    }

    private static func finishDependencies(_ room: Room, error: Error?) {
        let requests = dependencyRequests.removeValue(forKey: room.id) ?? []
        requests.forEach { $0.completion(error) }
    }

    /// Main-thread API. Once per engine version, also migrates existing rooms.
    static func prepare(_ room: Room, completion: @escaping (Error?) -> Void) {
        if let job = active[room.id] {
            job.completions.append { error in
                if let error { completion(error) } else { prepare(room, completion: completion) }
            }
            return
        }
        if isPrepared(room) { completion(nil); return }
        if Launcher.shared.hasRunningProcesses(in: room) {
            completion(SetupError("Bitte zuerst die Programme in „\(room.name)“ beenden. Danach richtet Virtual den Raum beim Start automatisch ein."))
            return
        }
        PrefixSetup().run(room, completion: completion)
    }

    func run(_ room: Room, task: Task = .setup, completion: ((Error?) -> Void)? = nil) {
        if let other = Self.active[room.id] {
            if let completion { other.completions.append(completion) }
            return
        }
        if let completion { completions.append(completion) }
        isRunning = true
        self.room = room
        self.task = task
        Self.active[room.id] = self
        NotificationCenter.default.post(name: Self.didChange, object: nil)

        let settings = Settings.shared
        guard !Updater.shared.isInstalling else {
            finish(status: -1, error: Launcher.LaunchError.updateInProgress)
            return
        }
        let script = settings.assetsRoot.appendingPathComponent(task.script)
        guard settings.runtimeIsInstalled, FileManager.default.fileExists(atPath: script.path) else {
            finish(status: -1, error: SetupError("Die Windows-Umgebung dieser Virtual-Version ist unvollständig. Bitte Virtual erneut aus dem vollständigen App-Archiv installieren."))
            return
        }
        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        switch task {
        case .components(let components): process.arguments = [script.path] + components
        case .graphics(let backend): process.arguments = [script.path, "--" + backend]
        default: process.arguments = [script.path, room.windowsVersion]
        }
        var env = RoomStore.shared.environment(for: room)
        env["WINMAC_ROOT"] = settings.root.path
        env["WINMAC_ASSETS_ROOT"] = settings.assetsRoot.path
        env["WINMAC_RUNTIME"] = settings.runtimePath.path
        process.environment = env

        // Services inherit stdout. Reading a growing file avoids waiting for pipe EOF.
        do {
            try FileManager.default.createDirectory(at: settings.logsPath, withIntermediateDirectories: true)
            let log = settings.logsPath.appendingPathComponent("setup-\(room.id)-\(UUID()).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let writer = try FileHandle(forWritingTo: log)
            let reader = try FileHandle(forReadingFrom: log)
            process.standardOutput = writer
            process.standardError = writer
            let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                if let data = try? reader.readToEnd(), !data.isEmpty { self?.append(String(decoding: data, as: UTF8.self)) }
            }
            process.terminationHandler = { [self] proc in
                DispatchQueue.main.async {
                    timer.invalidate()
                    if let data = try? reader.readToEnd(), !data.isEmpty { self.append(String(decoding: data, as: UTF8.self)) }
                    try? reader.close()
                    try? writer.close()
                    var error: Error?
                    if proc.terminationStatus != 0 {
                        error = SetupError("Die Einrichtung von „\(room.name)“ ist fehlgeschlagen (Status \(proc.terminationStatus)).\n\n\(self.output.suffix(2000))\n\nProtokoll: \(log.path)")
                    } else if task == .setup {
                        do {
                            guard room.isReady else { throw SetupError("Die Windows-Umgebung wurde nicht vollständig angelegt.") }
                            let marker = Self.marker(in: room)
                            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try settings.preparationVersion.write(to: marker, atomically: true, encoding: .utf8)
                        } catch let failure { error = failure }
                    }
                    self.finish(status: error == nil ? 0 : -1, error: error)
                }
            }
            do { try process.run() } catch {
                timer.invalidate()
                try? reader.close()
                try? writer.close()
                finish(status: -1, error: error)
            }
        } catch { finish(status: -1, error: error) }
    }

    func cancel() { process?.terminate() }

    private func append(_ text: String) {
        output = String((output + text).suffix(8000))
        NotificationCenter.default.post(name: Self.didLog, object: self, userInfo: ["line": text, "room": room!.id])
    }
    private func finish(status: Int32, error: Error?) {
        isRunning = false
        process = nil
        let roomID = room!.id
        Self.active[roomID] = nil
        if status == 0, task == .setup, roomID == RoomStore.shared.defaultRoom.id { Settings.shared.didInitPrefix = true }
        NotificationCenter.default.post(name: Self.didFinish, object: self, userInfo: ["status": status, "room": roomID])
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        let callbacks = completions
        completions.removeAll()
        callbacks.forEach { $0(error) }
    }

    struct SetupError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
