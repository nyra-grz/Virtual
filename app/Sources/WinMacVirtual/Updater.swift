import AppKit

/// Auto-Update über GitHub-Releases: Gibt es dort eine neuere Version als die laufende,
/// wird das App-Archiv geladen, das Bundle ausgetauscht und die App neu gestartet.
/// Ist ~/WinMac_Virtual ein sauberer Git-Checkout dieses Repos, kommen die Skripte
/// (init-prefix.sh, setup-graphics.sh …) per `git pull --ff-only` mit.
final class Updater {
    static let shared = Updater()
    static let repo = "nyra-grz/Virtual"

    struct Release {
        let version: String
        let notes: String
        let archive: URL
    }

    enum UpdateError: LocalizedError {
        case server(Int)
        case noArchive
        case download
        case badArchive
        case tool(String, Int32)

        var errorDescription: String? {
            switch self {
            case .server(404): return "Auf GitHub gibt es noch keine veröffentlichte Version."
            case .server(let code): return "GitHub antwortet mit Status \(code)."
            case .noArchive: return "Das neueste Release enthält kein App-Archiv (.zip)."
            case .download: return "Das App-Archiv konnte nicht geladen werden."
            case .badArchive: return "Das Archiv enthält keine passende Virtual-App in der angekündigten Version."
            case .tool(let name, let status): return "\(name) ist gescheitert (Status \(status))."
            }
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var isWorking = false

    // MARK: - Oberfläche

    /// Beim Start: höchstens einmal am Tag und still, solange alles aktuell ist.
    func checkOnLaunch() {
        let settings = Settings.shared
        guard settings.autoUpdate else { return }
        if let last = settings.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
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
                    if interactive { self.show("Virtual ist aktuell", "Version \(self.currentVersion) ist die neueste.") }
                case .success(let release):
                    self.offer(release)
                }
            }
        }
    }

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Virtual \(release.version) ist verfügbar"
        var info = "Installiert ist \(currentVersion)."
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(800)) }
        alert.informativeText = info
        alert.addButton(withTitle: "Jetzt aktualisieren")
        alert.addButton(withTitle: "Später")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Ein Neustart würde laufenden Programmen die Ausgabe-Pipe wegnehmen.
        guard !Launcher.shared.hasRunning else {
            show("Erst Programme beenden", "Bitte beende die laufenden Windows-Programme und suche dann erneut nach Updates.")
            return
        }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try self.install(release) }
            DispatchQueue.main.async {
                self.isWorking = false
                switch result {
                case .failure(let error):
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
            let scripts = try install(release)
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
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let api = try decoder.decode(APIRelease.self, from: data)
        guard let zip = api.assets.first(where: { $0.name.hasSuffix(".zip") }) else { throw UpdateError.noArchive }
        return Release(version: Self.plain(api.tagName), notes: api.body ?? "", archive: zip.browserDownloadUrl)
    }

    /// Lädt und entpackt das Archiv, prüft die App darin und ersetzt das laufende Bundle.
    /// Gibt einen Hinweis zu den Projekt-Skripten zurück (leer, wenn es keinen gibt).
    func install(_ release: Release) throws -> String {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL
        // Gleiches Volume wie das Bundle, damit der Austausch ein schnelles Umbenennen ist.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent("update.zip")

        let failure = Box<Error>()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.downloadTask(with: release.archive) { tmp, response, error in
            // Die temporäre Datei existiert nur bis zum Ende dieses Handlers.
            if let tmp, (response as? HTTPURLResponse)?.statusCode == 200 {
                do { try fm.moveItem(at: tmp, to: zip) } catch { failure.value = error }
            } else {
                failure.value = error ?? UpdateError.download
            }
            done.signal()
        }.resume()
        done.wait()
        if let error = failure.value { throw error }

        try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        guard let app = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) == release.version
        else { throw UpdateError.badArchive }
        try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

        _ = try fm.replaceItemAt(target, withItemAt: app)
        return updateScripts()
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
