import XCTest
@testable import WinMacVirtual

final class HousekeeperTests: XCTestCase {
    private let room = Room(name: "Standard", prefixPath: "/tmp/virtual-housekeeper-test/prefix")
    private let other = Room(name: "Spiele", prefixPath: "/tmp/virtual-housekeeper-test/spiele")
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func process(_ pid: pid_t, _ name: String, room: Room?, server: Bool = false, runner: Bool = false) -> Housekeeper.WineProcess {
        .init(pid: pid, name: name, prefix: room.map { Housekeeper.canonical($0.prefixPath) }, isServer: server, isRunner: runner)
    }

    private func decide(_ processes: [Housekeeper.WineProcess], visible: Set<pid_t> = [], busy: Set<UUID> = [],
                        state: inout Housekeeper.State, at seconds: TimeInterval, immediately: Bool = false) -> [Housekeeper.Action] {
        Housekeeper.decide(processes: processes, rooms: [room, other], visible: visible, inUse: { busy.contains($0.id) },
                           state: &state, now: start + seconds, idleLimit: 300, orphanGrace: 30, immediately: immediately)
    }

    private var backgroundOnly: [Housekeeper.WineProcess] {
        [process(10, "/engine/bin/wineserver", room: room, server: true),
         process(11, "C:\\windows\\system32\\services.exe", room: room),
         process(12, "C:\\Program Files (x86)\\Microsoft\\EdgeUpdate\\MicrosoftEdgeUpdate.exe", room: room)]
    }

    func testRoomWithOnlyBackgroundProcessesEndsAfterTheIdleLimit() {
        var state = Housekeeper.State()
        XCTAssertEqual(decide(backgroundOnly, state: &state, at: 0), [])
        XCTAssertEqual(decide(backgroundOnly, state: &state, at: 299), [])
        XCTAssertEqual(decide(backgroundOnly, state: &state, at: 300), [.stopRoom(room.id)])
        XCTAssertNil(state.idleSince[room.id])
    }

    func testProgramsStartedByVirtualKeepTheRoomEvenWithoutWindows() {
        var state = Housekeeper.State()
        // program-runner.exe lebt, solange das gestartete Programm oder eines seiner Kinder läuft,
        // auch nach einem Neustart von Virtual.
        let runner = backgroundOnly + [process(13, "/Applications/Virtual.app/Contents/Resources/program-runner.exe", room: room, runner: true)]
        XCTAssertEqual(decide(runner, state: &state, at: 0), [])
        XCTAssertEqual(decide(runner, state: &state, at: 3600), [])
        // In dieser Sitzung verfolgte Starts zählen genauso.
        XCTAssertEqual(decide(backgroundOnly, busy: [room.id], state: &state, at: 7200, immediately: true), [])
    }

    func testAWindowResetsTheIdleTime() {
        var state = Housekeeper.State()
        XCTAssertEqual(decide(backgroundOnly, state: &state, at: 0), [])
        XCTAssertEqual(decide(backgroundOnly, visible: [12], state: &state, at: 200), [])
        XCTAssertEqual(decide(backgroundOnly, state: &state, at: 400), [])
        XCTAssertEqual(decide(backgroundOnly, state: &state, at: 699), [])
        XCTAssertEqual(decide(backgroundOnly, state: &state, at: 700), [.stopRoom(room.id)])
    }

    func testQuittingEndsIdleRoomsAtOnceButNotRoomsInUse() {
        var state = Housekeeper.State()
        let busyRoom = [process(20, "/engine/bin/wineserver", room: other, server: true),
                        process(21, "C:\\Games\\Game.exe", room: other)]
        XCTAssertEqual(decide(backgroundOnly + busyRoom, visible: [21], state: &state, at: 0, immediately: true),
                       [.stopRoom(room.id)])
    }

    func testProcessesWithoutServerAreKilledOnlyWhenStillOrphanedLater() {
        var state = Housekeeper.State()
        let orphans = [process(30, "C:\\windows\\system32\\services.exe", room: room),
                       process(31, "C:\\windows\\system32\\winedevice.exe", room: room)]
        XCTAssertEqual(decide(orphans, state: &state, at: 0), [])
        XCTAssertEqual(decide(orphans, state: &state, at: 29), [])
        XCTAssertEqual(decide(orphans, state: &state, at: 30), [.killOrphans([30, 31])])
        // Ein Raum, dessen Server inzwischen läuft (gerade gestartet), ist nicht verwaist.
        state = Housekeeper.State()
        XCTAssertEqual(decide(orphans, state: &state, at: 0), [])
        let started = orphans + [process(32, "/engine/bin/wineserver", room: room, server: true)]
        XCTAssertEqual(decide(started, busy: [room.id], state: &state, at: 60), [])
        XCTAssertTrue(state.orphanSince.isEmpty)
    }

    func testProcessesOfOtherPrefixesAreLeftAlone() {
        var state = Housekeeper.State()
        let foreign = Room(name: "Fremd", prefixPath: "/tmp/somewhere-else")
        let processes = [process(40, "C:\\windows\\system32\\services.exe", room: foreign),
                         process(41, "C:\\tool.exe", room: nil)]
        XCTAssertEqual(decide(processes, state: &state, at: 0), [])
        XCTAssertEqual(decide(processes, state: &state, at: 3600), [])
    }

    func testArgumentsSurviveWinesShiftedArgv() throws {
        // argc 3 (Loader, Windows-Pfad, Argument); Wine hat argv um eins nach vorn geschoben
        // und Nullbytes hinterlassen, danach folgt die Umgebung.
        var buffer = withUnsafeBytes(of: Int32(3)) { Array($0) }
        buffer += Array("/engine/bin/wine".utf8) + [0, 0, 0]
        buffer += Array("C:\\Program Files\\App\\app.exe".utf8) + [0] + Array("/c".utf8) + [0]
        buffer += [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        buffer += Array("WINEPREFIX=/Users/x/WinMac_Virtual/prefix".utf8) + [0] + Array("HOME=/Users/x".utf8) + [0, 0]
        let parsed = try XCTUnwrap(Housekeeper.parseArguments(buffer))
        XCTAssertEqual(parsed.args.first, "C:\\Program Files\\App\\app.exe")
        XCTAssertEqual(parsed.prefix, "/Users/x/WinMac_Virtual/prefix")
        XCTAssertEqual(Housekeeper.WineProcess(pid: 1, name: parsed.args[0], prefix: nil, isServer: false, isRunner: false).shortName, "app.exe")
    }

    func testFindsLiveProcessesOfTheTestRunnerItself() {
        // Kein Wine nötig: die eigene Prozessliste muss sich lesen lassen, ohne Engine-Treffer.
        XCTAssertFalse(Housekeeper.wineProcesses().contains { $0.pid == getpid() })
        XCTAssertNotNil(Housekeeper.arguments(of: getpid()))
    }
}
