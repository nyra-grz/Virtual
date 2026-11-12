import XCTest
@testable import WinMacVirtual

final class ProgramImportTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Virtual import \(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("WINMAC_ROOT", root.appendingPathComponent("Virtual").path, 1)
    }
    override func tearDownWithError() throws {
        unsetenv("WINMAC_ROOT")
        try fm.removeItem(at: root)
    }
    @discardableResult private func file(_ path: String, text: String = "fixture") throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func scan() throws -> [ProgramImport.Candidate] {
        try ProgramImport.scan(roots: [root.appendingPathComponent("Downloads")], excluding: []).candidates
    }
    func testScanPreservesFoldersAndSkipsAliasesPackagesAndExistingRooms() throws {
        try file("Downloads/Portable/bin/App.EXE")
        try file("Downloads/Portable/tools/Helper.exe")
        try file("Downloads/Setup.MSI")
        try file("Downloads/Ignore.app/Hidden.exe")
        try file("Downloads/.hidden/Hidden.exe")
        let excluded = try file("Downloads/Virtual/prefix/Existing.exe").deletingLastPathComponent().deletingLastPathComponent()
        let alias = root.appendingPathComponent("Downloads/Alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("Downloads/Portable"))
        let result = try ProgramImport.scan(roots: [root.appendingPathComponent("Downloads"), root.appendingPathComponent("Downloads/Portable")], excluding: [excluded])
        XCTAssertEqual(result.candidates.map(\.name).sorted(), ["Portable", "Setup.MSI"])
        XCTAssertEqual(result.candidates.first(where: { $0.name == "Portable" })?.executables.count, 2)
    }
    func testCopyPreservesDllsDataAndWorkingDirectoryWithoutChangingOriginals() throws {
        let app = try file("Downloads/Portable/bin/App.exe", text: "program")
        try file("Downloads/Portable/bin/engine.dll", text: "library")
        try file("Downloads/Portable/assets/data.bin", text: "assets")
        let drive = root.appendingPathComponent("Virtual/prefix/drive_c")
        let copies = try ProgramImport.copy(scan(), to: drive)
        let copied = try XCTUnwrap(copies.first?.executables.first)
        XCTAssertTrue(ProgramImport.contains(drive, copied))
        XCTAssertTrue(fm.contentsEqual(atPath: app.path, andPath: copied.path))
        XCTAssertEqual(try String(contentsOf: copied.deletingLastPathComponent().appendingPathComponent("engine.dll")), "library")
        XCTAssertEqual(try String(contentsOf: copied.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets/data.bin")), "assets")
        XCTAssertTrue(fm.fileExists(atPath: app.path))
        let room = Room(name: "Test", prefixPath: drive.deletingLastPathComponent().path)
        let library = Library()
        let programs = try library.addImported(urls: copies.flatMap(\.executables), to: room)
        XCTAssertEqual(programs.map(\.path), [copied.path])
        XCTAssertEqual(Library().programs.first?.path, copied.path)
    }
    func testRepeatedImportsDoNotOverwriteEarlierCopies() throws {
        try file("Downloads/Setup.exe", text: "first")
        let drive = root.appendingPathComponent("Virtual/drive_c")
        let first = try ProgramImport.copy(scan(), to: drive)
        try file("Downloads/Setup.exe", text: "second")
        let second = try ProgramImport.copy(scan(), to: drive)
        XCTAssertNotEqual(first[0].destination, second[0].destination)
        XCTAssertEqual(try String(contentsOf: first[0].executables[0]), "first")
        XCTAssertEqual(try String(contentsOf: second[0].executables[0]), "second")
    }
    func testFailureInSecondGroupRollsBackWholeBatchAndPreservesOriginals() throws {
        let first = try file("Downloads/A.exe")
        try file("Downloads/B/App.exe")
        try fm.createSymbolicLink(at: root.appendingPathComponent("Downloads/B/external.dll"), withDestinationURL: first)
        let drive = root.appendingPathComponent("Virtual/drive_c")
        XCTAssertThrowsError(try ProgramImport.copy(scan(), to: drive))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: drive.appendingPathComponent("Virtual Imports").path), [])
        XCTAssertTrue(fm.fileExists(atPath: first.path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Downloads/B/App.exe").path))
    }
    func testCancellationRollsBackCompletedGroups() throws {
        try file("Downloads/A.exe"); try file("Downloads/B.exe")
        var cancelled = false
        let drive = root.appendingPathComponent("Virtual/drive_c")
        XCTAssertThrowsError(try ProgramImport.copy(scan(), to: drive, cancelled: { cancelled }, progress: { i, _ in if i == 1 { cancelled = true } }))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: drive.appendingPathComponent("Virtual Imports").path), [])
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Downloads/A.exe").path))
    }
    func testLibraryWriteFailureDoesNotPublishEntriesOrTouchOriginals() throws {
        let original = try file("Downloads/Setup.exe")
        let drive = root.appendingPathComponent("Virtual/drive_c")
        let copies = try ProgramImport.copy(scan(), to: drive)
        let room = Room(name: "Test", prefixPath: drive.deletingLastPathComponent().path)
        let library = Library()
        try fm.createDirectory(at: root.appendingPathComponent("Virtual/library.json"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try library.addImported(urls: copies.flatMap(\.executables), to: room))
        XCTAssertTrue(library.programs.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: original.path))
        try ProgramImport.discard(copies)
        XCTAssertFalse(fm.fileExists(atPath: copies[0].destination.path))
    }
    func testRejectsSourceContainingDestinationAndRedirectedImportDirectory() throws {
        let original = try file("Downloads/Portable/App.exe")
        let candidate = try XCTUnwrap(scan().first)
        XCTAssertThrowsError(try ProgramImport.copy([candidate], to: candidate.source.appendingPathComponent("drive_c")))
        let drive = root.appendingPathComponent("Virtual/drive_c")
        let other = root.appendingPathComponent("Elsewhere")
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: drive.appendingPathComponent("Virtual Imports"), withDestinationURL: other)
        XCTAssertThrowsError(try ProgramImport.copy([candidate], to: drive))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: other.path), [])
        XCTAssertTrue(fm.fileExists(atPath: original.path))
    }
    func testScanMeasuresContentAndBlocksFoldersWithLinks() throws {
        try file("Downloads/Portable/App.exe", text: String(repeating: "a", count: 1000))
        try file("Downloads/Portable/data/.hidden.bin", text: String(repeating: "b", count: 24))
        let linked = try file("Downloads/Linked/App.exe")
        try fm.createSymbolicLink(at: root.appendingPathComponent("Downloads/Linked/shared.dll"), withDestinationURL: linked)
        let candidates = try scan()
        let portable = try XCTUnwrap(candidates.first { $0.name == "Portable" })
        // Hidden files count too: copy() takes them along.
        XCTAssertEqual(portable.size, 1024)
        XCTAssertEqual(portable.fileCount, 2)
        XCTAssertNil(portable.blocker)
        XCTAssertTrue(portable.isSafeDefault)
        let blocked = try XCTUnwrap(candidates.first { $0.name == "Linked" })
        XCTAssertNotNil(blocked.blocker)
        XCTAssertFalse(blocked.isSafeDefault)
    }
    func testWorkTreesWithManyExecutablesAreNotSelectedByDefault() throws {
        for i in 0...ProgramImport.defaultExecutableLimit { try file("Downloads/Builds/run\(i)/tool\(i).exe") }
        try file("Downloads/Setup.exe")
        let candidates = try scan()
        XCTAssertFalse(try XCTUnwrap(candidates.first { $0.name == "Builds" }).isSafeDefault)
        XCTAssertTrue(try XCTUnwrap(candidates.first { $0.name == "Setup.exe" }).isSafeDefault)
    }
    func testLibraryGetsMainProgramsButNotHelpers() {
        let dir = root.appendingPathComponent("Game")
        let exes = ["Game.exe", "unins000.exe", "CrashSender.exe", "vc_redist.x64.exe", "Uninstall.exe"].map { dir.appendingPathComponent($0) }
        XCTAssertEqual(ProgramImport.libraryExecutables(exes).map(\.lastPathComponent), ["Game.exe"])
        // A lone file is always the user's explicit choice.
        XCTAssertEqual(ProgramImport.libraryExecutables([dir.appendingPathComponent("vc_redist.x64.exe")]).count, 1)
        XCTAssertEqual(ProgramImport.libraryExecutables(Array(exes.dropFirst(2))).count, 1)
    }
    func testClonesOnTheSameVolumeNeedNoSpace() throws {
        let source = try file("Downloads/Setup.exe")
        let destination = root.appendingPathComponent("Virtual/drive_c")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let clones = (try destination.resourceValues(forKeys: [.volumeSupportsFileCloningKey])).volumeSupportsFileCloning == true
        XCTAssertEqual(ProgramImport.requiredSpace(for: [(source, 5_000_000)], destination: destination), clones ? 0 : 5_000_000)
    }
    func testMissingExecutableSincePreviewIsRejected() throws {
        try file("Downloads/Portable/App.exe")
        let candidate = try XCTUnwrap(scan().first)
        let drive = root.appendingPathComponent("Virtual/drive_c")
        // An executable disappearing after the preview must not produce a successful import.
        try fm.removeItem(at: candidate.executables[0])
        XCTAssertThrowsError(try ProgramImport.copy([candidate], to: drive))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: drive.appendingPathComponent("Virtual Imports").path), [])
    }
}
