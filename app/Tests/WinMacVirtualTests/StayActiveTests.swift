import XCTest
@testable import WinMacVirtual

final class StayActiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Virtual stay-active \(UUID())")
        setenv("WINMAC_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        unsetenv("WINMAC_ROOT")
    }

    private func touch(_ url: URL, _ text: String = "x") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testSteamAppIDFromLaunchArguments() {
        XCTAssertEqual(StayActive.steamAppID("-applaunch 284160"), "284160")
        XCTAssertEqual(StayActive.steamAppID("-silent -applaunch  42 -gfx dx11"), "42")
        XCTAssertEqual(StayActive.steamAppID("steam://rungameid/284160"), "284160")
        XCTAssertNil(StayActive.steamAppID("-silent"))
    }

    func testSteamGameFolderFromManifestInSecondLibrary() throws {
        let room = Room(name: "Test", prefixPath: root.appendingPathComponent("room").path)
        let steam = room.driveC.appendingPathComponent("Program Files (x86)/Steam")
        try touch(steam.appendingPathComponent("steamapps/libraryfolders.vdf"), """
        "libraryfolders"
        {
            "0" { "path"  "C:\\\\Program Files (x86)\\\\Steam" }
            "1" { "path"  "C:\\\\Games\\\\SteamLib" }
        }
        """)
        let lib = room.driveC.appendingPathComponent("Games/SteamLib/steamapps")
        try touch(lib.appendingPathComponent("appmanifest_7.acf"), "\"AppState\"\n{\n\t\"appid\"\t\t\"7\"\n\t\"installdir\"\t\t\"Some Game\"\n}\n")
        try touch(lib.appendingPathComponent("common/Some Game/Bin64/Game.x64.exe"))
        try touch(lib.appendingPathComponent("common/Some Game/Launcher.exe"))
        let folder = try XCTUnwrap(StayActive.steamGameFolder("7", steam: steam))
        XCTAssertEqual(folder.lastPathComponent, "Some Game")
        XCTAssertEqual(Set(StayActive.executables(in: folder, depth: 4)), ["Game.x64.exe", "Launcher.exe"])
        XCTAssertNil(StayActive.steamGameFolder("8", steam: steam))
    }

    func testProgramFolderSkipsSharedFolders() {
        let room = Room(name: "Test", prefixPath: root.appendingPathComponent("room").path)
        let c = room.driveC
        XCTAssertNotNil(StayActive.programFolder(of: c.appendingPathComponent("Program Files/Tool/tool.exe"), in: room))
        XCTAssertNotNil(StayActive.programFolder(of: c.appendingPathComponent("Games/Foo/foo.exe"), in: room))
        XCTAssertNil(StayActive.programFolder(of: c.appendingPathComponent("Program Files/tool.exe"), in: room))
        XCTAssertNil(StayActive.programFolder(of: c.appendingPathComponent("windows/system32/notepad.exe"), in: room))
        XCTAssertNil(StayActive.programFolder(of: c.appendingPathComponent("users/Timur/Downloads/x.exe"), in: room))
        XCTAssertNil(StayActive.programFolder(of: URL(fileURLWithPath: "/tmp/x.exe"), in: room))
    }

    func testFolderWalkSkipsSteamLibrariesAndRespectsDepth() throws {
        let folder = root.appendingPathComponent("Steam")
        try touch(folder.appendingPathComponent("steam.exe"))
        try touch(folder.appendingPathComponent("bin/cef/steamwebhelper.exe"))
        try touch(folder.appendingPathComponent("steamapps/common/Game/game.exe"))
        try touch(folder.appendingPathComponent("a/b/c/d/deep.exe"))
        XCTAssertEqual(Set(StayActive.executables(in: folder, depth: 3)), ["steam.exe", "steamwebhelper.exe"])
    }

    func testListIsLowercasedUniqueAndRemovedWhenEmpty() throws {
        let list = root.appendingPathComponent("prefix/.virtual/stay-active")
        try StayActive.write(["Game.EXE", "game.exe", "Launcher.exe"], to: list)
        let lines = try String(contentsOf: list, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(lines, ["game.exe", "launcher.exe"])
        try StayActive.write([], to: list)
        XCTAssertFalse(FileManager.default.fileExists(atPath: list.path))
    }

    func testDirectExecutableIncludesItsProgramFolder() throws {
        let room = RoomStore.shared.create(name: "Stay \(UUID())")
        let exe = room.driveC.appendingPathComponent("Games/Racer/Racer.exe")
        try touch(exe)
        try touch(room.driveC.appendingPathComponent("Games/Racer/Bin64/Racer.x64.exe"))
        let program = try XCTUnwrap(Library.shared.add(url: exe, to: room))
        XCTAssertEqual(Set(StayActive.executables(for: program)), ["Racer.exe", "Racer.x64.exe"])
        Library.shared.remove(program)
    }
}
