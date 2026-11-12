import AppKit
import Darwin

/// Räumt Wine im Hintergrund auf, damit ohne laufendes Programm nichts Akku, CPU und RAM frisst:
/// – Wine-Prozesse, deren Server nicht mehr läuft, sind verwaist und können nichts mehr tun;
///   sie werden beendet, wenn sie auch bei der nächsten Prüfung noch ohne Server sind.
/// – Ein Raum, in dem kein von Virtual gestartetes Programm mehr läuft und kein Fenster offen ist,
///   wird nach `idleLimit` beendet (übrig gebliebene Updater, Hilfsprogramme, Dienste) und beim
///   Beenden von Virtual sofort.
/// Gestartete Programme erkennt Virtual auch nach einem Neustart: Jeder Start läuft über
/// program-runner.exe, das weiterläuft, solange das Programm oder eines seiner Kinder lebt.
final class Housekeeper {
    static let shared = Housekeeper()

    /// Ein Prozess aus einer Virtual-Engine.
    struct WineProcess: Equatable {
        let pid: pid_t
        /// Erstes Argument, bei Windows-Programmen der Windows-Pfad (wie in der Aktivitätsanzeige).
        let name: String
        /// WINEPREFIX, aufgelöst; nil, wenn der Prozess keinen hat.
        let prefix: String?
        let isServer: Bool
        let isRunner: Bool

        /// Kurzer Name für Protokolle, z. B. „MicrosoftEdgeUpdate.exe“.
        var shortName: String {
            name.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? name
        }
    }

    enum Action: Equatable {
        case killOrphans([pid_t])
        case stopRoom(UUID)
    }

    /// Was zwischen zwei Prüfungen gemerkt wird.
    struct State {
        var idleSince: [UUID: Date] = [:]
        var orphanSince: [pid_t: Date] = [:]
    }

    /// Wie lange ein Raum ohne Programm und Fenster weiterlaufen darf (WINMAC_IDLE_LIMIT in Sekunden für Tests).
    static var idleLimit: TimeInterval {
        ProcessInfo.processInfo.environment["WINMAC_IDLE_LIMIT"].flatMap(TimeInterval.init) ?? 5 * 60
    }
    static let orphanGrace: TimeInterval = 30
    static let interval: TimeInterval = 60

    /// Wines eigene Hilfsprozesse; im Protokoll nur zusammengefasst.
    static let wineSystemNames: Set<String> = ["services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe",
                                               "rpcss.exe", "explorer.exe", "conhost.exe", "wineboot.exe",
                                               "start.exe", "winemenubuilder.exe", "wineserver"]

    private var state = State()
    private var timer: Timer?
    private var stopping: Set<UUID> = []
    private var checking = false

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Reste von früher (vor dem Start von Virtual) gleich erfassen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.check() }
    }

    /// Eine Prüfung: Prozesse im Hintergrund erfassen, auf dem Main-Thread entscheiden und handeln.
    func check() {
        guard Settings.shared.autoCleanup else { state = State(); return }
        guard !checking, !Updater.shared.isInstalling else { return }
        checking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let processes = Self.wineProcesses()
            let visible = Self.visiblePIDs(among: Set(processes.map(\.pid)))
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                guard Settings.shared.autoCleanup, !Updater.shared.isInstalling else { return }
                let rooms = RoomStore.shared.rooms
                let actions = Self.decide(processes: processes, rooms: rooms, visible: visible,
                                          inUse: { self.isBusy($0) }, state: &self.state, now: Date(),
                                          idleLimit: Self.idleLimit, orphanGrace: Self.orphanGrace)
                self.perform(actions, processes: processes, rooms: rooms, atQuit: false)
            }
        }
    }

    /// Beim Beenden von Virtual: Räume ohne Programm und Fenster sofort schließen. Programme, die
    /// Virtual gestartet hat, laufen weiter. Wartet nicht; `wineserver -k` läuft selbstständig zu Ende.
    func cleanUpOnQuit() {
        guard Settings.shared.autoCleanup, !Updater.shared.isInstalling else { return }
        let processes = Self.wineProcesses()
        guard !processes.isEmpty else { return }
        let visible = Self.visiblePIDs(among: Set(processes.map(\.pid)))
        let rooms = RoomStore.shared.rooms
        var quitState = State()
        let actions = Self.decide(processes: processes, rooms: rooms, visible: visible, inUse: isBusy,
                                  state: &quitState, now: Date(), idleLimit: Self.idleLimit,
                                  orphanGrace: Self.orphanGrace, immediately: true)
        perform(actions, processes: processes, rooms: rooms, atQuit: true)
    }

    /// Startet oder verfolgt Virtual in diesem Raum gerade selbst etwas?
    private func isBusy(_ room: Room) -> Bool {
        stopping.contains(room.id) || Launcher.shared.hasRunning(in: room) || PrefixSetup.current(in: room) != nil
    }

    // MARK: Entscheidung (rein, testbar)

    /// `visible`: Prozesse mit Fenster auf dem Bildschirm oder Dock-Symbol. `immediately` überspringt
    /// die Wartezeit für leerlaufende Räume (beim Beenden von Virtual), nicht die für verwaiste Prozesse.
    static func decide(processes: [WineProcess], rooms: [Room], visible: Set<pid_t>, inUse: (Room) -> Bool,
                       state: inout State, now: Date, idleLimit: TimeInterval, orphanGrace: TimeInterval,
                       immediately: Bool = false) -> [Action] {
        var byPrefix: [String: [WineProcess]] = [:]
        for process in processes { if let prefix = process.prefix { byPrefix[prefix, default: []].append(process) } }

        var actions: [Action] = []
        var orphans = Set<pid_t>()
        var known = Set<UUID>()
        for room in rooms {
            known.insert(room.id)
            guard let group = byPrefix[canonical(room.prefixPath)], !group.isEmpty else {
                state.idleSince[room.id] = nil
                continue
            }
            guard group.contains(where: \.isServer) else {
                orphans.formUnion(group.map(\.pid))
                state.idleSince[room.id] = nil
                continue
            }
            if inUse(room) || group.contains(where: { $0.isRunner || visible.contains($0.pid) }) {
                state.idleSince[room.id] = nil
                continue
            }
            let since = state.idleSince[room.id] ?? now
            if immediately || now.timeIntervalSince(since) >= idleLimit {
                actions.append(.stopRoom(room.id))
                state.idleSince[room.id] = nil
            } else {
                state.idleSince[room.id] = since
            }
        }
        state.idleSince = state.idleSince.filter { known.contains($0.key) }

        state.orphanSince = state.orphanSince.filter { orphans.contains($0.key) }
        var expired: [pid_t] = []
        for pid in orphans.sorted() {
            let since = state.orphanSince[pid] ?? now
            if now.timeIntervalSince(since) >= orphanGrace {
                expired.append(pid)
                state.orphanSince[pid] = nil
            } else {
                state.orphanSince[pid] = since
            }
        }
        if !expired.isEmpty { actions.insert(.killOrphans(expired), at: 0) }
        return actions
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Handeln

    private func perform(_ actions: [Action], processes: [WineProcess], rooms: [Room], atQuit: Bool) {
        for action in actions {
            switch action {
            case .killOrphans(let pids):
                var ended: [String] = []
                for pid in pids {
                    // Seit der Erfassung könnte die Nummer neu vergeben sein: nur Engine-Prozesse beenden.
                    guard Self.executablePath(pid)?.contains("/wine-build/") == true, kill(pid, SIGKILL) == 0 else { continue }
                    ended.append("\(processes.first { $0.pid == pid }?.shortName ?? "?") (\(pid))")
                }
                if !ended.isEmpty { log("Verwaiste Wine-Prozesse ohne Server beendet: " + ended.joined(separator: ", ")) }
            case .stopRoom(let id):
                guard let room = rooms.first(where: { $0.id == id }), !stopping.contains(id) else { continue }
                let prefix = Self.canonical(room.prefixPath)
                let names = Set(processes.filter { $0.prefix == prefix }.map(\.shortName))
                    .subtracting(Self.wineSystemNames).sorted()
                let what = names.isEmpty ? "nur Wine-Dienste" : names.joined(separator: ", ")
                let limit = Int(Self.idleLimit)
                let reason = atQuit ? "beim Beenden von Virtual" : limit % 60 == 0 ? "nach \(limit / 60) Min." : "nach \(limit) s"
                log("Raum „\(room.name)“ \(reason) beendet, kein Programm und kein Fenster mehr offen (\(what))")
                if atQuit {
                    Self.stopDetached(room)
                } else {
                    stopping.insert(id)
                    Launcher.shared.stopAll(in: [room]) { [weak self] failed in
                        self?.stopping.remove(id)
                        if !failed.isEmpty { self?.log("Raum „\(room.name)“: Ende nicht bestätigt, nächste Prüfung versucht es erneut") }
                    }
                }
            }
        }
    }

    /// `wineserver -k` ohne zu warten; läuft weiter, auch wenn Virtual gleich endet.
    private static func stopDetached(_ room: Room) {
        let process = Process()
        process.executableURL = Settings.shared.virtualServer
        process.arguments = ["-k"]
        process.environment = RoomStore.shared.environment(for: room)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func log(_ line: String) {
        let folder = Settings.shared.logsPath
        let url = folder.appendingPathComponent("hintergrund.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let data = Data("\(formatter.string(from: Date())) \(line)\n".utf8)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: Prozesse erfassen

    /// Alle eigenen Prozesse aus Virtual-Engines (ausführbare Datei unter …/wine-build/).
    static func wineProcesses() -> [WineProcess] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        var result: [WineProcess] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            guard let executable = executablePath(pid), executable.contains("/wine-build/"),
                  let info = arguments(of: pid) else { continue }
            let name = info.args.first ?? executable
            result.append(WineProcess(pid: pid, name: name, prefix: info.prefix.map(canonical),
                                      isServer: (executable as NSString).lastPathComponent == "wineserver",
                                      isRunner: name.lowercased().hasSuffix("program-runner.exe")))
        }
        return result
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Argumente und WINEPREFIX eines eigenen Prozesses, wie `ps` sie liest (KERN_PROCARGS2).
    static func arguments(of pid: pid_t) -> (args: [String], prefix: String?)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseArguments(Array(buffer.prefix(size)))
    }

    /// Aufbau: argc (Int32), Pfad der ausführbaren Datei, Nullbytes, argv, Umgebung. Wine schiebt
    /// argv um eins nach vorn und lässt dahinter Nullbytes stehen; darum wird WINEPREFIX unter allen
    /// Zeichenketten gesucht (die letzte gewinnt, die Umgebung steht hinter den Argumenten).
    static func parseArguments(_ buffer: [UInt8]) -> (args: [String], prefix: String?)? {
        guard buffer.count > 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        var strings: [String] = []
        while index < buffer.count {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.count
            if end > index { strings.append(String(decoding: buffer[index..<end], as: UTF8.self)) }
            index = end + 1
        }
        let key = "WINEPREFIX="
        let prefix = strings.last { $0.hasPrefix(key) }.map { String($0.dropFirst(key.count)) }
        return (Array(strings.prefix(max(argc, 1))), prefix)
    }

    /// Prozesse mit sichtbarem Fenster oder Dock-Symbol. Wine-Programme ohne gezeigtes Fenster
    /// (Updater, Dienste, Programme nur im Hintergrund) haben beides nicht.
    static func visiblePIDs(among pids: Set<pid_t>) -> Set<pid_t> {
        guard !pids.isEmpty else { return [] }
        var visible = Set<pid_t>()
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { continue }
            if let bounds = window[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: bounds), rect.width < 2 || rect.height < 2 { continue }
            visible.insert(pid)
        }
        for pid in pids where NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular {
            visible.insert(pid)
        }
        return visible
    }
}
