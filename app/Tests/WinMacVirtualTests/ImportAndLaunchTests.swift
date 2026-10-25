import XCTest
@testable import WinMacVirtual

final class ImportAndLaunchTests: XCTestCase {
    private var root: URL!
    private var tokens: [NSObjectProtocol] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Virtual tests \(UUID())")
        let assets = root.appendingPathComponent("App assets")
        let runtime = assets.appendingPathComponent("runtime")
        setenv("WINMAC_ROOT", root.path, 1)
        setenv("WINMAC_ASSETS_ROOT", assets.path, 1)
        setenv("WINMAC_RUNTIME", runtime.path, 1)
        try write("test-engine-1", to: assets.appendingPathComponent("engine-version"))
        try write("""
        #!/bin/bash
        mkdir -p "$WINEPREFIX/drive_c/windows/system32"
        printf 'setup\\n' >> "$WINMAC_ROOT/setup-runs"
        sleep 0.2
        if [ -f "$WINMAC_ROOT/fail-setup" ]; then echo 'test: setup failed'; exit 17; fi
        """, to: assets.appendingPathComponent("scripts/init-prefix.sh"), executable: true)
        try write("""
        #!/bin/bash
        printf '%s\\n' "$PWD" > "$WINEPREFIX/launched-cwd"
        printf '%s\\n' "$@" > "$WINEPREFIX/launched-args"
        if [ -f "$WINMAC_ROOT/fail-unknown" ]; then echo 'err:module:import_dll Library vendor_private.dll not found'; exit 4; fi
        if [ -f "$WINMAC_ROOT/fail-launch" ]; then echo 'err:module:import_dll Library VCRUNTIME140.dll not found'; exit 4; fi
        """, to: runtime.appendingPathComponent("bin/virtual"), executable: true)
    }

    override func tearDownWithError() throws {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
        try FileManager.default.removeItem(at: root)
        unsetenv("WINMAC_ROOT"); unsetenv("WINMAC_ASSETS_ROOT"); unsetenv("WINMAC_RUNTIME")
    }

    private func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }
    private func room() -> Room { RoomStore.shared.create(name: "Test \(UUID())") }
    private func program(in room: Room, filename: String = "Portable App.EXE") throws -> Program {
        let file = root.appendingPathComponent("Downloads with spaces/\(filename)")
        try write("test executable", to: file)
        return try XCTUnwrap(Library.shared.add(url: file, to: room))
    }
    private func observe(_ name: Notification.Name, count: Int = 1, check: @escaping (Notification) -> Void = { _ in }) -> XCTestExpectation {
        let done = expectation(description: name.rawValue)
        done.expectedFulfillmentCount = count
        tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            check(note); done.fulfill()
        })
        return done
    }
    private var setupRuns: Int {
        ((try? String(contentsOf: root.appendingPathComponent("setup-runs"))) ?? "").split(separator: "\n").count
    }

    func testFirstLaunchPreparesRoomAndPreservesWorkingDirectory() throws {
        let room = room(), app = try program(in: room)
        let done = observe(Launcher.didFinishInRoom)
        try Launcher.shared.launch(app)
        XCTAssertTrue(Launcher.shared.isPreparing(app))
        wait(for: [done], timeout: 5)
        XCTAssertTrue(PrefixSetup.isPrepared(room))
        XCTAssertEqual(setupRuns, 1)
        let cwd = try String(contentsOf: room.prefixURL.appendingPathComponent("launched-cwd")).trimmingCharacters(in: .newlines)
        XCTAssertEqual(URL(fileURLWithPath: cwd).resolvingSymlinksInPath(), app.url.deletingLastPathComponent().resolvingSymlinksInPath())
        XCTAssertFalse(Launcher.shared.isRunning(app))
    }

    func testParallelLaunchesSharePreparation() throws {
        let room = room()
        let a = try program(in: room, filename: "One.exe"), b = try program(in: room, filename: "Two.exe")
        let done = observe(Launcher.didFinishInRoom, count: 2)
        try Launcher.shared.launch(a); try Launcher.shared.launch(b)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(setupRuns, 1)
    }

    func testPreparationFailureDoesNotLaunchOrMarkRoomPrepared() throws {
        try write("fail", to: root.appendingPathComponent("fail-setup"))
        let room = room(), app = try program(in: room)
        let done = observe(Launcher.didFail) { note in
            XCTAssertTrue((note.userInfo?["message"] as? String)?.contains("test: setup failed") == true)
        }
        try Launcher.shared.launch(app)
        wait(for: [done], timeout: 5)
        XCTAssertFalse(PrefixSetup.isPrepared(room))
        XCTAssertFalse(FileManager.default.fileExists(atPath: room.prefixURL.appendingPathComponent("launched-cwd").path))
        XCTAssertFalse(Launcher.shared.isRunning(app))
    }

    func testCancellingPendingLaunchDoesNotStartApp() throws {
        let room = room(), app = try program(in: room)
        let done = observe(PrefixSetup.didFinish)
        try Launcher.shared.launch(app)
        Launcher.shared.stop(app)
        wait(for: [done], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: room.prefixURL.appendingPathComponent("launched-cwd").path))
    }

    func testEngineUpdateMigratesExistingRoomAndSameVersionIsCached() throws {
        let room = room()
        for version in ["test-engine-1", "test-engine-1", "test-engine-2"] {
            try write(version, to: Settings.shared.assetsRoot.appendingPathComponent("engine-version"))
            let done = expectation(description: "prepare \(version)")
            PrefixSetup.prepare(room) { error in XCTAssertNil(error); done.fulfill() }
            wait(for: [done], timeout: 5)
        }
        XCTAssertEqual(setupRuns, 2)
    }

    func testInstallerUsesMsiExecAfterPreparation() throws {
        let room = room(), installer = try program(in: room, filename: "An installer.msi")
        let done = observe(Launcher.didFinishInRoom)
        try Launcher.shared.launch(installer)
        wait(for: [done], timeout: 5)
        let args = try String(contentsOf: room.prefixURL.appendingPathComponent("launched-args"))
        XCTAssertTrue(args.hasPrefix("msiexec\n/i\n"))
        XCTAssertTrue(args.contains("An installer.msi"))
    }

    func testNonzeroExitProducesActionableDiagnostic() throws {
        try write("fail", to: root.appendingPathComponent("fail-unknown"))
        let room = room(), app = try program(in: room)
        let done = observe(Launcher.didFail) { note in
            let message = note.userInfo?["message"] as? String ?? ""
            XCTAssertTrue(message.contains("vendor_private.dll"))
            XCTAssertTrue(message.contains("vollständigen Windows-Installer"))
        }
        try Launcher.shared.launch(app)
        wait(for: [done], timeout: 5)
    }

    func testImportAcceptsShortcutsAndDeduplicatesPerRoom() throws {
        let a = room(), b = room()
        let shortcut = root.appendingPathComponent("My App.LNK")
        try write("shortcut", to: shortcut)
        let first = try XCTUnwrap(Library.shared.add(url: shortcut, to: a))
        XCTAssertEqual(Library.shared.add(url: shortcut, to: a)?.id, first.id)
        XCTAssertNotEqual(Library.shared.add(url: shortcut, to: b)?.id, first.id)
        XCTAssertNil(Library.shared.add(url: root.appendingPathComponent("Missing.exe"), to: a))
        let directory = root.appendingPathComponent("Folder.exe")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertNil(Library.shared.add(url: directory, to: a))
    }

    func testRegistryOnlyInstallationsAreDiscoveredWithoutShortcuts() throws {
        let room = room()
        let exe = room.driveC.appendingPathComponent("Program Files/Editor/editor.exe")
        try write("app", to: exe)
        let path = String(decoding: try JSONEncoder().encode("C:\\Program Files\\Editor\\editor.exe"), as: UTF8.self)
        let reg = "[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\App Paths\\\\editor.exe]\n@=\(path)\n"
        try write(reg, to: room.prefixURL.appendingPathComponent("system.reg"))
        let apps = AppScanner.scan(room)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.path, exe.path)
    }

    func testDetectedSamePathCanBelongToDifferentRooms() throws {
        let a = room(), b = room()
        let found = [(name: "Shared shortcut", path: root.appendingPathComponent("shared.lnk").path)]
        XCTAssertEqual(Library.shared.syncDetected(found, in: a).count, 1)
        XCTAssertEqual(Library.shared.syncDetected(found, in: b).count, 1)
    }

    func testFailedPreparationCanBeRetried() throws {
        let room = room()
        try write("fail", to: root.appendingPathComponent("fail-setup"))
        let failed = expectation(description: "failed setup")
        PrefixSetup.prepare(room) { error in XCTAssertNotNil(error); failed.fulfill() }
        wait(for: [failed], timeout: 5)
        try FileManager.default.removeItem(at: root.appendingPathComponent("fail-setup"))
        let ready = expectation(description: "retried setup")
        PrefixSetup.prepare(room) { error in XCTAssertNil(error); ready.fulfill() }
        wait(for: [ready], timeout: 5)
        XCTAssertTrue(PrefixSetup.isPrepared(room))
        XCTAssertEqual(setupRuns, 2)
    }

    func testToolsAlsoPrepareAnEmptyRoom() throws {
        let room = room()
        let done = observe(Launcher.didFinishInRoom)
        try Launcher.shared.runTool(["explorer"], in: room, title: "Explorer")
        wait(for: [done], timeout: 5)
        XCTAssertTrue(PrefixSetup.isPrepared(room))
        XCTAssertEqual(setupRuns, 1)
    }

    func testWindowsExitCodesArePreservedAndMsiRebootIsSuccess() {
        XCTAssertEqual(LaunchDiagnostics.exitCode(status: 194, output: "test\nVIRTUAL_EXIT_CODE=3010\n\nBeendet"), 3010)
        XCTAssertEqual(LaunchDiagnostics.exitCode(status: 53, output: "VIRTUAL_EXIT_CODE=3221225781\n"), Int32(bitPattern: 0xc0000135))
        XCTAssertTrue(LaunchDiagnostics.installerSucceeded(status: 3010, isMSI: true))
        XCTAssertTrue(LaunchDiagnostics.installerSucceeded(status: 194, isMSI: true))
        XCTAssertFalse(LaunchDiagnostics.installerSucceeded(status: 194, isMSI: false))
        XCTAssertFalse(LaunchDiagnostics.installerSucceeded(status: 1603, isMSI: true))
    }

    func testParallelAppsInstallDependencyUnionBeforeEitherStarts() throws {
        let room = room()
        let first = try program(in: room, filename: "Needs VC.exe")
        let second = try program(in: room, filename: "Needs compiler.exe")
        try ExecutableRequirementsTests.fixtureData(imports: ["vcruntime140.dll"]).write(to: first.url)
        try ExecutableRequirementsTests.fixtureData(imports: ["d3dcompiler_47.dll"]).write(to: second.url)
        try write("""
        #!/bin/bash
        printf 'dependencies\\n' >> "$WINMAC_ROOT/dependency-runs"
        mkdir -p "$WINEPREFIX/.virtual/components"
        for component in "$@"; do printf '%s' "$component" > "$WINEPREFIX/.virtual/components/$component"; done
        """, to: Settings.shared.assetsRoot.appendingPathComponent("scripts/setup-dependencies.sh"), executable: true)
        let done = observe(Launcher.didFinishInRoom, count: 2)
        try Launcher.shared.launch(first); try Launcher.shared.launch(second)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("dependency-runs")), "dependencies\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: room.prefixURL.appendingPathComponent(".virtual/components/vcrun2026").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: room.prefixURL.appendingPathComponent(".virtual/components/d3dcompiler_47").path))
    }

    func testDependencyInstallFailureDoesNotStartProgram() throws {
        let room = room(), app = try program(in: room)
        try ExecutableRequirementsTests.fixtureData(imports: ["vcruntime140.dll"]).write(to: app.url)
        try write("#!/bin/bash\necho 'component install failed'\nexit 23\n", to: Settings.shared.assetsRoot.appendingPathComponent("scripts/setup-dependencies.sh"), executable: true)
        let done = observe(Launcher.didFail) { note in
            XCTAssertTrue((note.userInfo?["message"] as? String)?.contains("component install failed") == true)
        }
        try Launcher.shared.launch(app)
        wait(for: [done], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: room.prefixURL.appendingPathComponent("launched-cwd").path))
    }

    func testMissingRuntimeIsInstalledAndProgramRetriesOnce() throws {
        let room = room(), app = try program(in: room)
        try write("fail", to: root.appendingPathComponent("fail-launch"))
        try write("""
        #!/bin/bash
        mkdir -p "$WINEPREFIX/.virtual/components"
        for component in "$@"; do printf '%s' "$component" > "$WINEPREFIX/.virtual/components/$component"; done
        rm "$WINMAC_ROOT/fail-launch"
        """, to: Settings.shared.assetsRoot.appendingPathComponent("scripts/setup-dependencies.sh"), executable: true)
        var failures = 0
        tokens.append(NotificationCenter.default.addObserver(forName: Launcher.didFail, object: nil, queue: .main) { _ in failures += 1 })
        let done = observe(Launcher.didFinishInRoom, count: 2)
        try Launcher.shared.launch(app)
        wait(for: [done], timeout: 5)
        XCTAssertEqual(failures, 0)
        XCTAssertFalse(Launcher.shared.isRunning(app))
        XCTAssertTrue(FileManager.default.fileExists(atPath: room.prefixURL.appendingPathComponent(".virtual/components/vcrun2026").path))
    }

    func testHelpWireNameIsNotMistakenForHelpShortcut() throws {
        let room = room()
        let link = room.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs/HelpWire.lnk")
        try write("shortcut", to: link)
        XCTAssertTrue(AppScanner.scan(room).contains { $0.name == "HelpWire" })
    }
}
