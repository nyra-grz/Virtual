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
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("WinMac_Virtual")
    }

    /// Ordner mit den `virtual*`-Befehlen (erzeugt von build-wine.sh bzw. make-runtime-from-brew.sh).
    var runtimePath: URL {
        get {
            if let s = defaults.string(forKey: Key.runtimePath), !s.isEmpty {
                return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
            }
            return root.appendingPathComponent("runtime")
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

    /// Prüft, ob eine lauffähige Runtime vorhanden ist.
    var runtimeIsInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: virtualBinary.path)
    }
}
