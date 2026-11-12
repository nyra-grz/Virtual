import AppKit
import CryptoKit

/// Auto-Update über GitHub-Releases: Virtual prüft beim Start und danach alle vier Stunden, ob es
/// dort eine neuere Version gibt. Läuft gerade ein Windows-Programm oder ist ein Spiel vorn, wartet
/// das Angebot, bis es beendet ist. Ein Release besteht aus der App (klein) und engine.json, das die
/// passende Engine beschreibt; die große Engine wird nur geladen, wenn sie sich von der installierten
/// unterscheidet. Ist ~/WinMac_Virtual ein sauberer Git-Checkout dieses Repos, kommen die Skripte
/// (init-prefix.sh, setup-graphics.sh …) per `git pull --ff-only` mit.
final class Updater {
    static let shared = Updater()
    static let repo = "nyra-grz/Virtual"
    /// Abstand der automatischen Prüfungen, solange Virtual läuft.
    static let checkInterval: TimeInterval = 4 * 3600

    struct Release {
        let version: String
        let notes: String
        let archive: URL
        /// Aus engine.json; nil bei älteren Releases, deren Archiv die Engine selbst enthält.
        let engine: EngineManifest?
    }

    /// Inhalt von engine.json: welche Engine zur App gehört und wo sie liegt.
    struct EngineManifest: Codable, Equatable {
        /// Inhalt von Engine/engine-version (Prüfsumme über die ganze Engine).
        let version: String
        let url: URL
        let size: Int64
        let sha256: String
    }

    enum UpdateError: LocalizedError {
        case server(Int)
        case noArchive
        case download
        case badArchive
        case badEngine
        case tool(String, Int32)

        var errorDescription: String? {
            switch self {
            case .server(404): return "Auf GitHub gibt es noch keine veröffentlichte Version."
            case .server(let code): return "GitHub antwortet mit Status \(code)."
            case .noArchive: return "Das neueste Release enthält kein App-Archiv (.zip)."
            case .download: return "Das Update konnte nicht geladen werden."
            case .badArchive: return "Das Archiv enthält keine passende Virtual-App in der angekündigten Version."
            case .badEngine: return "Die geladene Engine ist unvollständig oder beschädigt. Bitte später erneut versuchen."
            case .tool(let name, let status): return "\(name) ist gescheitert (Status \(status))."
            }
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Engine der laufenden App (fehlt bei Entwickler-Builds ohne eingebaute Engine).
    private var installedEngine: URL? { Bundle.main.resourceURL?.appendingPathComponent("Engine") }

    private var isWorking = false
    private(set) var isInstalling = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    /// Gefunden, während ein Programm lief; wird angeboten, sobald nichts mehr läuft.
    private var pending: Release?

    // MARK: - Oberfläche

    /// Beim Start (höchstens einmal pro Stunde) und danach alle `checkInterval`, solange Virtual läuft.
    func checkOnLaunch() {
        if timer == nil {
            let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.automaticCheck() }
            timer.tolerance = 600
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            observer = NotificationCenter.default.addObserver(forName: Launcher.didChange, object: nil, queue: .main) { [weak self] _ in
                self?.offerPendingIfIdle()
            }
        }
        if let last = Settings.shared.lastUpdateCheck, Date().timeIntervalSince(last) < 3600 { return }
        automaticCheck()
    }

    private func automaticCheck() {
        guard Settings.shared.autoUpdate else { return }
        check(interactive: false)
    }

    /// Menü „Nach Updates suchen…“: meldet auch „aktuell“ und Fehler.
    func check(interactive: Bool) {
        guard !isWorking else { return }
        isWorking = true
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try self.latestRelease() }
            DispatchQueue.main.async {
                self.isWorking = false
                Settings.shared.lastUpdateCheck = Date()
                switch result {
                case .failure(let error):
                    if interactive { self.show("Update-Prüfung fehlgeschlagen", error.localizedDescription) }
                case .success(let release) where !Self.isNewer(release.version, than: self.currentVersion):
                    self.pending = nil
                    if interactive { self.show("Virtual ist aktuell", "Version \(self.currentVersion) ist die neueste.") }
                case .success(let release):
                    if interactive || !self.userIsBusy {
                        self.pending = nil
                        self.offer(release)
                    } else {
                        self.pending = release
                    }
                }
            }
        }
    }

    /// Läuft ein Windows-Programm, wird ein Raum eingerichtet oder ist ein Wine-Fenster vorn
    /// (etwa ein Spiel, das schon vor diesem Start von Virtual lief)?
    private var userIsBusy: Bool {
        if Launcher.shared.hasRunning || PrefixSetup.hasRunning { return true }
        return NSWorkspace.shared.frontmostApplication?.executableURL?.path.contains("/wine-build/") == true
    }

    private func offerPendingIfIdle() {
        guard let release = pending, !isWorking, !isInstalling, !userIsBusy else { return }
        pending = nil
        offer(release)
    }

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Virtual \(release.version) ist verfügbar"
        var info = "Installiert ist \(currentVersion)."
        if let engine = release.engine, Self.engineVersion(at: installedEngine) != engine.version {
            info += " Dazu kommt eine neue Engine (\(ByteCountFormatter.string(fromByteCount: engine.size, countStyle: .file)) Download)."
        }
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(800)) }
        alert.informativeText = info
        alert.addButton(withTitle: "Jetzt aktualisieren")
        alert.addButton(withTitle: "Später")
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Während des Austauschs darf kein Programm aus dem alten Bundle starten.
        guard !Launcher.shared.hasRunning else {
            show("Erst Programme beenden", "Bitte beende die laufenden Windows-Programme und suche dann erneut nach Updates.")
            return
        }
        isWorking = true
        isInstalling = true
        let window = UpdateProgressWindow(title: "Virtual \(release.version) wird installiert")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try self.install(release) { text, fraction in
                    DispatchQueue.main.async { window.update(text, fraction) }
                }
            }
            DispatchQueue.main.async {
                window.close()
                self.isWorking = false
                switch result {
                case .failure(let error):
                    self.isInstalling = false
                    self.show("Update fehlgeschlagen", error.localizedDescription)
                case .success(let scripts):
                    self.show("Update installiert", "Virtual \(release.version) startet jetzt neu.\(scripts.isEmpty ? "" : "\n\n" + scripts)")
                    self.relaunch()
                }
            }
        }
    }

    private func show(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    /// Wartet, bis dieser Prozess beendet ist, und öffnet dann das (neue) Bundle.
    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - Ohne Oberfläche

    /// `Virtual --update`: prüfen und installieren ohne Fenster (für Skripte und Tests).
    func runFromCommandLine() -> Int32 {
        do {
            let release = try latestRelease()
            guard Self.isNewer(release.version, than: currentVersion) else {
                print("Virtual \(currentVersion) ist aktuell.")
                return 0
            }
            print("Aktualisiere \(currentVersion) → \(release.version) …")
            var last = ""
            let scripts = try install(release) { text, fraction in
                let line = fraction.map { "\(text) \(Int($0 * 100)) %" } ?? text
                guard line != last, fraction == nil || Int((fraction ?? 0) * 100) % 10 == 0 else { return }
                last = line
                print(line)
            }
            print("Installiert: \(Bundle.main.bundleURL.path)")
            if !scripts.isEmpty { print(scripts) }
            return 0
        } catch {
            FileHandle.standardError.write("Update fehlgeschlagen: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }

    // MARK: - Ablauf (blockierend, nicht auf dem Main-Thread aufrufen)

    func latestRelease() throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data = try fetch(request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let api = try decoder.decode(APIRelease.self, from: data)
        let version = Self.plain(api.tagName)
        guard let zip = Self.appArchive(in: api.assets.map(\.name), version: version),
              let archive = api.assets.first(where: { $0.name == zip })?.browserDownloadUrl else { throw UpdateError.noArchive }
        var engine: EngineManifest?
        if let manifest = api.assets.first(where: { $0.name == "engine.json" }) {
            engine = try JSONDecoder().decode(EngineManifest.self, from: fetch(URLRequest(url: manifest.browserDownloadUrl)))
        }
        return Release(version: version, notes: api.body ?? "", archive: archive, engine: engine)
    }

    /// Das App-Archiv eines Releases: Virtual-<Version>.zip, sonst ein anderes .zip außer der Engine.
    static func appArchive(in names: [String], version: String) -> String? {
        if names.contains("Virtual-\(version).zip") { return "Virtual-\(version).zip" }
        return names.first { $0.hasSuffix(".zip") && !$0.hasPrefix("Virtual-Engine-") }
    }

    /// Lädt die App, setzt die passende Engine ein, prüft alles und ersetzt das laufende Bundle.
    /// Gibt einen Hinweis zu den Projekt-Skripten zurück (leer, wenn es keinen gibt).
    func install(_ release: Release, progress: @escaping (String, Double?) -> Void = { _, _ in }) throws -> String {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        // Gleiches Volume wie das Bundle: Klonen der Engine und Austausch sind schnell.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: work) }

        let zip = work.appendingPathComponent("update.zip")
        progress("Lade Virtual \(release.version) …", nil)
        try download(release.archive, to: zip) { progress("Lade Virtual \(release.version) …", $0) }
        try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        try? fm.removeItem(at: zip)
        guard let app = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) == release.version
        else { throw UpdateError.badArchive }

        try Self.assembleEngine(in: app, manifest: release.engine, installed: installedEngine) { manifest in
            let file = work.appendingPathComponent("engine.zip")
            let size = ByteCountFormatter.string(fromByteCount: manifest.size, countStyle: .file)
            try self.download(manifest.url, to: file) { progress("Lade die Engine (\(size)) …", $0) }
            progress("Prüfe die Engine …", nil)
            let bytes = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
            guard bytes == manifest.size, try Self.sha256(of: file) == manifest.sha256 else { throw UpdateError.badEngine }
            progress("Entpacke die Engine …", nil)
            return file
        }
        guard fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/Resources/Engine/runtime/bin/virtual").path)
        else { throw UpdateError.badArchive }

        progress("Installiere …", nil)
        // Die App kommt ohne Engine signiert; mit Engine neu versiegeln (ad hoc, wie build-app.sh).
        try? Self.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
        try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        _ = try fm.replaceItemAt(target, withItemAt: app)
        return updateScripts()
    }

    /// Setzt die Engine in die geladene App. Steckt sie schon im Archiv (ältere Releases), bleibt es
    /// dabei; hat die installierte App dieselbe Engine-Version, wird diese geklont (APFS, ohne
    /// Download); sonst liefert `fetch` ein geprüftes Zip mit dem Ordner „Engine“.
    static func assembleEngine(in app: URL, manifest: EngineManifest?, installed: URL?,
                               fetch: (EngineManifest) throws -> URL) throws {
        let fm = FileManager.default
        let resources = app.appendingPathComponent("Contents/Resources")
        let engine = resources.appendingPathComponent("Engine")
        if engineVersion(at: engine) != nil { return }
        guard let manifest else { throw UpdateError.badArchive }
        if let installed, engineVersion(at: installed) == manifest.version {
            try fm.copyItem(at: installed, to: engine)
        } else {
            let zip = try fetch(manifest)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, resources.path])
            try? fm.removeItem(at: zip)
        }
        guard engineVersion(at: engine) == manifest.version else {
            try? fm.removeItem(at: engine)
            throw UpdateError.badEngine
        }
    }

    static func engineVersion(at engine: URL?) -> String? {
        guard let engine, let text = try? String(contentsOf: engine.appendingPathComponent("engine-version"), encoding: .utf8) else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Kleine Antwort (Release-Daten, engine.json) laden.
    private func fetch(_ request: URLRequest) throws -> Data {
        var request = request
        request.timeoutInterval = 20
        let reply = Box<(Data?, URLResponse?, Error?)>()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            reply.value = (data, response, error)
            done.signal()
        }.resume()
        done.wait()
        if let error = reply.value?.2 { throw error }
        let status = (reply.value?.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let data = reply.value?.0 else { throw UpdateError.server(status) }
        return data
    }

    /// Lädt `url` nach `destination` und meldet den Anteil (0…1).
    private func download(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void) throws {
        let failure = Box<Error>()
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
            // Die temporäre Datei existiert nur bis zum Ende dieses Handlers.
            if let tmp, (response as? HTTPURLResponse)?.statusCode == 200 || url.isFileURL {
                do { try FileManager.default.moveItem(at: tmp, to: destination) } catch { failure.value = error }
            } else {
                failure.value = error ?? UpdateError.download
            }
            done.signal()
        }
        let observation = task.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
        task.resume()
        done.wait()
        observation.invalidate()
        if let error = failure.value { throw error }
    }

    /// Skripte im Projektordner nachziehen – nur in einem sauberen Checkout dieses Repos.
    private func updateScripts() -> String {
        let root = Settings.shared.root
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return "" }
        guard let origin = git(["remote", "get-url", "origin"]), origin.contains(Self.repo) else {
            return "Der Projektordner ist kein Checkout von \(Self.repo) – Skripte unverändert."
        }
        guard git(["status", "--porcelain", "--untracked-files=no"]) == "" else {
            return "Der Projektordner hat lokale Änderungen – Skripte unverändert (selbst: git pull --ff-only)."
        }
        guard git(["pull", "--ff-only", "--quiet"]) != nil else {
            return "git pull im Projektordner ist gescheitert – Skripte unverändert."
        }
        return "Skripte im Projektordner sind aktualisiert."
    }

    /// git im Projektordner; Ausgabe ohne Zeilenumbruch am Ende, nil bei Fehler.
    private func git(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", Settings.shared.root.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.tool((tool as NSString).lastPathComponent, p.terminationStatus) }
    }

    // MARK: - Versionen

    private static func plain(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// 1.10.0 > 1.9.3 – numerisch pro Stelle, fehlende Stellen zählen als 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = plain(a).split(separator: ".").map { Int($0) ?? 0 }
        let y = plain(b).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private struct APIRelease: Decodable {
        let tagName: String
        let body: String?
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
    }

    /// Ergebnis-Fach für Completion-Handler, auf die per Semaphore gewartet wird.
    private final class Box<T>: @unchecked Sendable {
        var value: T?
    }
}

/// Fenster mit Fortschritt, solange ein Update lädt und installiert.
private final class UpdateProgressWindow {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "Bereite das Update vor …")
    private let bar = NSProgressIndicator()

    init(title: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 96), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let content = NSView()
        window.contentView = content
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        for view in [label, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func update(_ text: String, _ fraction: Double?) {
        label.stringValue = text
        if let fraction {
            if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false }
            bar.doubleValue = fraction
        } else if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    func close() { window.close() }
}
