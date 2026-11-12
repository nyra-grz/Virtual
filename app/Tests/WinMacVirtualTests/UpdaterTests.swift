import XCTest
@testable import WinMacVirtual

final class UpdaterTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Virtual updater \(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    /// Engine-Ordner mit engine-version und einer ausführbaren Runtime.
    @discardableResult private func engine(at url: URL, version: String) throws -> URL {
        try fm.createDirectory(at: url.appendingPathComponent("runtime/bin"), withIntermediateDirectories: true)
        try Data((version + "\n").utf8).write(to: url.appendingPathComponent("engine-version"))
        let virtual = url.appendingPathComponent("runtime/bin/virtual")
        try Data("#!/bin/sh\n".utf8).write(to: virtual)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: virtual.path)
        return url
    }

    private func app() throws -> URL {
        let app = root.appendingPathComponent("New/Virtual.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        return app
    }

    private func manifest(_ version: String) -> Updater.EngineManifest {
        .init(version: version, url: URL(string: "https://example.invalid/engine.zip")!, size: 1, sha256: "")
    }

    /// Zip wie aus release.sh: ditto -c -k --keepParent Engine …
    private func engineZip(version: String) throws -> URL {
        let source = try engine(at: root.appendingPathComponent("Zip/Engine"), version: version)
        let zip = root.appendingPathComponent("engine-\(version).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        try fm.removeItem(at: source.deletingLastPathComponent())
        return zip
    }

    func testPicksTheAppArchiveNotTheEngine() {
        XCTAssertEqual(Updater.appArchive(in: ["Virtual-Engine-1a2b.zip", "engine.json", "Virtual-0.8.0.zip"], version: "0.8.0"), "Virtual-0.8.0.zip")
        XCTAssertEqual(Updater.appArchive(in: ["Virtual-0.6.0.zip", "Virtual.verified.json"], version: "0.6.0"), "Virtual-0.6.0.zip")
        XCTAssertNil(Updater.appArchive(in: ["Virtual-Engine-1a2b.zip", "engine.json"], version: "0.8.0"))
    }

    func testSameEngineIsClonedWithoutDownload() throws {
        let app = try app()
        let installed = try engine(at: root.appendingPathComponent("Old/Engine"), version: "abc")
        try Updater.assembleEngine(in: app, manifest: manifest("abc"), installed: installed) { _ in
            XCTFail("Gleiche Engine darf nicht geladen werden"); throw Updater.UpdateError.download
        }
        XCTAssertEqual(Updater.engineVersion(at: app.appendingPathComponent("Contents/Resources/Engine")), "abc")
        XCTAssertTrue(fm.fileExists(atPath: installed.path), "Die installierte Engine bleibt, bis das Bundle getauscht wird")
    }

    func testChangedEngineIsDownloadedAndUnpacked() throws {
        let app = try app()
        let installed = try engine(at: root.appendingPathComponent("Old/Engine"), version: "old")
        let zip = try engineZip(version: "new")
        var fetched = 0
        try Updater.assembleEngine(in: app, manifest: manifest("new"), installed: installed) { _ in fetched += 1; return zip }
        XCTAssertEqual(fetched, 1)
        let engine = app.appendingPathComponent("Contents/Resources/Engine")
        XCTAssertEqual(Updater.engineVersion(at: engine), "new")
        XCTAssertTrue(fm.isExecutableFile(atPath: engine.appendingPathComponent("runtime/bin/virtual").path))
    }

    func testWrongEngineIsRejectedAndRemoved() throws {
        let app = try app()
        let zip = try engineZip(version: "other")
        XCTAssertThrowsError(try Updater.assembleEngine(in: app, manifest: manifest("new"), installed: nil) { _ in zip })
        XCTAssertFalse(fm.fileExists(atPath: app.appendingPathComponent("Contents/Resources/Engine").path))
    }

    func testOldFullArchivesKeepTheirEngineAndAppsWithoutEngineNeedAManifest() throws {
        let full = try app()
        try engine(at: full.appendingPathComponent("Contents/Resources/Engine"), version: "bundled")
        try Updater.assembleEngine(in: full, manifest: nil, installed: nil) { _ in throw Updater.UpdateError.download }
        XCTAssertEqual(Updater.engineVersion(at: full.appendingPathComponent("Contents/Resources/Engine")), "bundled")

        let bare = root.appendingPathComponent("Bare/Virtual.app")
        try fm.createDirectory(at: bare.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try Updater.assembleEngine(in: bare, manifest: nil, installed: nil) { _ in throw Updater.UpdateError.download })
    }

    func testSha256AndVersionOrder() throws {
        let file = root.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try Updater.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(Updater.isNewer("0.8.0", than: "0.7.6"))
        XCTAssertTrue(Updater.isNewer("v0.10.0", than: "0.9.9"))
        XCTAssertFalse(Updater.isNewer("0.6.0", than: "0.7.6"))
    }
}
