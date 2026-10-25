import Foundation

/// Zentrale Einstellungen und Pfade. Werte liegen in UserDefaults,
/// mit sinnvollen Vorgaben relativ zu ~/WinMac_Virtual.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    enum Key {
        static let runtimePath = "runtimePath"
        static let prefixPath   = "prefixPath"
        static let windowsVersion = "windowsVersion"
        static let didInitPrefix  = "didInitPrefix"
        static let autoUpdate     = "autoUpdate"
        static let lastUpdateCheck = "lastUpdateCheck"
    }

    /// ~/WinMac_Virtual – fester Wurzelordner des Projekts.
    var root: URL {
        if let path = ProcessInfo.processInfo.environment["WINMAC_ROOT"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("WinMac_Virtual")
    }

    /// Read-only setup assets shipped with the app; user data always stays in root.
    var assetsRoot: URL {
        if let path = ProcessInfo.processInfo.environment["WINMAC_ASSETS_ROOT"] { return URL(fileURLWithPath: path) }
        if let engine = Bundle.main.resourceURL?.appendingPathComponent("Engine"),
           FileManager.default.fileExists(atPath: engine.appendingPathComponent("engine-version").path) { return engine }
        return root
    }

    var preparationVersion: String {
        let engine = (try? String(contentsOf: assetsRoot.appendingPathComponent("engine-version"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = [assetsRoot.appendingPathComponent("scripts/init-prefix.sh"),
                     runtimePath.appendingPathComponent("wine-build/lib/wine/x86_64-unix/ntdll.so")]
        let dates = paths.map { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0).description }
        return "2|\(runtimePath.path)|\(engine ?? dates.joined(separator: "|"))"
    }

    /// Ordner mit den `virtual*`-Befehlen (erzeugt von build-wine.sh bzw. make-runtime-from-brew.sh).
    var runtimePath: URL {
        get {
            if let path = ProcessInfo.processInfo.environment["WINMAC_RUNTIME"] { return URL(fileURLWithPath: path) }
            if let s = defaults.string(forKey: Key.runtimePath), !s.isEmpty {
                let custom = URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
                if custom != root.appendingPathComponent("runtime") { return custom }
            }
            return assetsRoot.appendingPathComponent("runtime")
        }
        set { defaults.set(newValue.path, forKey: Key.runtimePath) }
    }

    /// Das `virtual`-Startprogramm im Runtime-Ordner.
    var virtualBinary: URL { runtimePath.appendingPathComponent("bin/virtual") }
    var virtualBoot: URL { runtimePath.appendingPathComponent("bin/virtualboot") }
    var virtualServer: URL { runtimePath.appendingPathComponent("bin/virtualserver") }

    /// Windows-Umgebung (WINEPREFIX).
    var prefixPath: URL {
        get {
            if let s = defaults.string(forKey: Key.prefixPath), !s.isEmpty {
                return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
            }
            return root.appendingPathComponent("prefix")
        }
        set { defaults.set(newValue.path, forKey: Key.prefixPath) }
    }

    var logsPath: URL { root.appendingPathComponent("logs") }

    /// Vorgegebene Windows-Version (für Erststart-Einrichtung).
    var windowsVersion: String {
        get { defaults.string(forKey: Key.windowsVersion) ?? "win10" }
        set { defaults.set(newValue, forKey: Key.windowsVersion) }
    }

    var didInitPrefix: Bool {
        get { defaults.bool(forKey: Key.didInitPrefix) }
        set { defaults.set(newValue, forKey: Key.didInitPrefix) }
    }

    /// Beim Start (höchstens einmal am Tag) auf GitHub nach einer neueren Version suchen.
    var autoUpdate: Bool {
        get { defaults.object(forKey: Key.autoUpdate) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoUpdate) }
    }

    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    var overlayEnabled: Bool {
        get { defaults.object(forKey: "overlayEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "overlayEnabled") }
    }
    var overlayShortcut: OverlayController.Shortcut {
        get {
            guard defaults.object(forKey: "overlayKey") != nil else { return .standard }
            return .init(key: UInt32(defaults.integer(forKey: "overlayKey")),
                         modifiers: UInt32(defaults.integer(forKey: "overlayModifiers")),
                         title: defaults.string(forKey: "overlayTitle") ?? "⌥⌘Z")
        }
        set {
            defaults.set(Int(newValue.key), forKey: "overlayKey")
            defaults.set(Int(newValue.modifiers), forKey: "overlayModifiers")
            defaults.set(newValue.title, forKey: "overlayTitle")
        }
    }

    /// Prüft, ob eine lauffähige Runtime vorhanden ist.
    var runtimeIsInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: virtualBinary.path)
    }
}
