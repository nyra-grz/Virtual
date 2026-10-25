// Listet die Fenster aller Prozesse (für scripts/compat-test.py): ID, PID, Besitzer, Titel, Größe, sichtbar.
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list {
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let name = w[kCGWindowName as String] as? String ?? ""
    let id = w[kCGWindowNumber as String] as? Int ?? 0
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    if CommandLine.arguments.count > 1 && !owner.lowercased().contains(CommandLine.arguments[1].lowercased()) && !name.lowercased().contains(CommandLine.arguments[1].lowercased()) { continue }
    print(id, pid, owner, "|", name, "|", b["Width"] ?? 0, "x", b["Height"] ?? 0, onscreen ? "on" : "off")
}
