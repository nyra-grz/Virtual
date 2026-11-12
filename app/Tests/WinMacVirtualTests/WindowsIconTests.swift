import XCTest
@testable import WinMacVirtual

final class WindowsIconTests: XCTestCase {
    /// Minimale .lnk nach MS-SHLLINK: Kopf, Arbeitsordner, Argumente und Symbol als Unicode-Zeichenketten.
    private func shortcut(icon: String, index: Int32, countNull: Bool) throws -> URL {
        var data = Data(count: 0x4C)
        func put32(_ value: UInt32, at offset: Int) { withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset..<offset + 4, with: $0) } }
        put32(0x4C, at: 0)
        put32(0x80 | 0x40 | 0x20 | 0x10, at: 0x14)       // IsUnicode, HasIconLocation, HasArguments, HasWorkingDir
        put32(UInt32(bitPattern: index), at: 0x38)
        for text in ["C:\\Program Files (x86)\\Steam", "-applaunch 284160", icon] {
            let units = Array((countNull ? text + "\0" : text).utf16)
            withUnsafeBytes(of: UInt16(units.count).littleEndian) { data.append(contentsOf: $0) }
            for unit in units { withUnsafeBytes(of: unit.littleEndian) { data.append(contentsOf: $0) } }
        }
        data.append(contentsOf: [0, 0, 0, 0])               // TerminalBlock
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID()).lnk")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testShortcutIconComesFromTheIconLocationNotTheLauncher() throws {
        // Wines Shell-Link zählt die abschließende Null mit, Windows nicht: beides muss gehen.
        for countNull in [true, false] {
            let url = try shortcut(icon: "C:\\Games\\BeamNG.drive\\BeamNG.drive.exe", index: 0, countNull: countNull)
            let icon = try XCTUnwrap(WindowsIcon.shortcutIcon(url))
            XCTAssertEqual(icon.path, "C:\\Games\\BeamNG.drive\\BeamNG.drive.exe")
            XCTAssertEqual(icon.index, 0)
        }
    }

    func testShortcutIconExpandsCommonVariablesAndKeepsNegativeIds() throws {
        let url = try shortcut(icon: "%SystemRoot%\\system32\\shell32.dll", index: -16, countNull: false)
        let icon = try XCTUnwrap(WindowsIcon.shortcutIcon(url))
        XCTAssertEqual(icon.path, "C:\\windows\\system32\\shell32.dll")
        XCTAssertEqual(icon.index, -16)
        // Unbekannte Variablen lassen sich nicht auflösen: dann gilt das Symbol des Ziels.
        XCTAssertNil(WindowsIcon.shortcutIcon(try shortcut(icon: "%LOCALAPPDATA%\\app.ico", index: 0, countNull: false)))
    }
}
