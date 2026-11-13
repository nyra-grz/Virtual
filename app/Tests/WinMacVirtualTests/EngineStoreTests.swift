import XCTest
@testable import WinMacVirtual

final class EngineStoreTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Virtual engine store \(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("WINMAC_ENGINE_STORE", root.appendingPathComponent("Support/Engine").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("WINMAC_ENGINE_STORE")
        try fm.removeItem(at: root)
    }

    /// Engine-Zip wie aus release.sh und das passende engine.json (mit file://-Adresse).
    private func release(version: String) throws -> Updater.EngineManifest {
        let source = root.appendingPathComponent("Build-\(version)/Engine")
        try fm.createDirectory(at: source.appendingPathComponent("runtime/bin"), withIntermediateDirectories: true)
        try Data((version + "\n").utf8).write(to: source.appendingPathComponent("engine-version"))
        let virtual = source.appendingPathComponent("runtime/bin/virtual")
        try Data("#!/bin/sh\n".utf8).write(to: virtual)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: virtual.path)
        let zip = root.appendingPathComponent("Virtual-Engine-\(version).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", source.path, zip.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let size = (try fm.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.int64Value ?? 0
        return .init(version: version, url: zip, size: size, sha256: try Updater.sha256(of: zip))
    }

    func testSlimAppUsesTheDownloadedEngine() throws {
        XCTAssertNil(EngineStore.version)
        try EngineStore.install(try release(version: "one"))
        XCTAssertEqual(EngineStore.version, "one")
        // Das Test-Bundle hat keine eingebaute Engine: Virtual nimmt die geladene.
        XCTAssertEqual(Settings.shared.assetsRoot.path, EngineStore.folder.path)
        XCTAssertTrue(Settings.shared.runtimeIsInstalled)
    }

    func testBrokenDownloadNeverReplacesAWorkingEngine() throws {
        try EngineStore.install(try release(version: "one"))
        let two = try release(version: "two")
        let corrupt = Updater.EngineManifest(version: two.version, url: two.url, size: two.size, sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try EngineStore.install(corrupt))
        XCTAssertEqual(EngineStore.version, "one")
        let truncated = Updater.EngineManifest(version: two.version, url: two.url, size: two.size + 1, sha256: two.sha256)
        XCTAssertThrowsError(try EngineStore.install(truncated))
        XCTAssertEqual(EngineStore.version, "one")

        try EngineStore.install(two)
        XCTAssertEqual(EngineStore.version, "two")
        let leftovers = try fm.contentsOfDirectory(atPath: EngineStore.folder.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".engine-") }
        XCTAssertEqual(leftovers, [], "Arbeitsordner werden immer weggeräumt")
    }

    func testEngineWithWrongVersionIsRejected() throws {
        let built = try release(version: "built")
        let mislabeled = Updater.EngineManifest(version: "announced", url: built.url, size: built.size, sha256: built.sha256)
        XCTAssertThrowsError(try EngineStore.install(mislabeled))
        XCTAssertNil(EngineStore.version)
    }
}
