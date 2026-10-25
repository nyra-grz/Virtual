import XCTest
@testable import WinMacVirtual

final class ExecutableRequirementsTests: XCTestCase {
    private var directory: URL!
    private var room: Room!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PE requirements \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        room = Room(name: "Test", prefixPath: directory.appendingPathComponent("prefix").path)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    static func fixtureData(imports: [String], clr: Bool = false, x64: Bool = true) -> Data {
        var bytes = [UInt8](repeating: 0, count: 2048)
        func word(_ offset: Int, _ value: UInt16) { bytes[offset] = UInt8(truncatingIfNeeded: value); bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8) }
        func dword(_ offset: Int, _ value: UInt32) { word(offset, UInt16(truncatingIfNeeded: value)); word(offset + 2, UInt16(truncatingIfNeeded: value >> 16)) }
        word(0, 0x5a4d); dword(0x3c, 0x80); dword(0x80, 0x4550)
        word(0x84, x64 ? 0x8664 : 0x14c); word(0x86, 1)
        word(0x94, x64 ? 240 : 224); word(0x98, x64 ? 0x20b : 0x10b)
        let directories = 0x98 + (x64 ? 112 : 96)
        dword(directories + 8, 0x1000)
        if clr { dword(directories + 14 * 8, 0x1400) }
        let section = 0x98 + (x64 ? 240 : 224)
        dword(section + 8, 1536); dword(section + 12, 0x1000); dword(section + 16, 1536); dword(section + 20, 512)
        for (index, name) in imports.enumerated() {
            let offset = 768 + index * 128
            dword(512 + index * 20 + 12, UInt32(0x1000 + offset - 512))
            for (i, byte) in name.utf8.enumerated() { bytes[offset + i] = byte }
        }
        if clr {
            for (i, byte) in "PresentationFramework".utf8.enumerated() { bytes[1800 + i] = byte }
        }
        return Data(bytes)
    }

    private func fixture(imports: [String], clr: Bool = false, x64: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent("Example.exe")
        try Self.fixtureData(imports: imports, clr: clr, x64: x64).write(to: url)
        return url
    }

    func testRecognizesOlderRuntimesAndDirectXHelpers() throws {
        let url = try fixture(imports: ["MSVCR90.dll", "msvbvm60.dll", "d3dx11_43.dll", "PhysXLoader.dll", "msxml6.dll"])
        XCTAssertEqual(ExecutableRequirements.inspect(url, in: room).components,
                       ["d3dx11_43", "msxml6", "physx", "vb6run", "vcrun2008"])
    }

    func testRecognizesVcAndDirectXImports() throws {
        let url = try fixture(imports: ["MSVCP140.dll", "VCRUNTIME140_1.dll", "D3DCOMPILER_47.dll"])
        XCTAssertEqual(ExecutableRequirements.inspect(url, in: room).components, ["d3dcompiler_47", "vcrun2026"])
    }
    func testLegacyVcAndD3dxRecipes() throws {
        let url = try fixture(imports: ["MSVCR120.dll", "D3DX9_43.dll"])
        XCTAssertEqual(ExecutableRequirements.inspect(url, in: room).components, ["d3dx9", "vcrun2013"])
    }
    func testModernDesktopConfigChoosesArchitectureAndDoesNotReplaceMono() throws {
        let url = try fixture(imports: [], clr: true, x64: false)
        let config = #"{"runtimeOptions":{"frameworks":[{"name":"Microsoft.NETCore.App","version":"8.0.0"},{"name":"Microsoft.WindowsDesktop.App","version":"8.0.0"}]}}"#
        try Data(config.utf8).write(to: url.deletingPathExtension().appendingPathExtension("runtimeconfig.json"))
        let result = ExecutableRequirements.inspect(url, in: room)
        XCTAssertEqual(result.components, ["dotnetdesktop8-x86@8.0.0"])
        XCTAssertFalse(result.needsDotNet48)
    }
    func testClassicWpfRequiresNativeDotNet48() throws {
        let url = try fixture(imports: ["mscoree.dll"], clr: true)
        XCTAssertTrue(ExecutableRequirements.inspect(url, in: room).needsDotNet48)
    }
    func testMalformedPeDoesNotCrashOrGuessDependencies() throws {
        let url = directory.appendingPathComponent("Broken.exe")
        for bytes in [Data(), Data([0x4d, 0x5a]), Data(repeating: 0xff, count: 100)] {
            try bytes.write(to: url)
            XCTAssertEqual(ExecutableRequirements.inspect(url, in: room).components, [])
        }
    }

    func testDependenciesInAdjacentDllAreDiscovered() throws {
        let url = try fixture(imports: ["engine.dll"])
        try Self.fixtureData(imports: ["vcruntime140_1.dll"]).write(to: directory.appendingPathComponent("engine.dll"))
        XCTAssertEqual(ExecutableRequirements.inspect(url, in: room).components, ["vcrun2026"])
    }

    func testImportPathsCannotReadOutsideAppDirectory() throws {
        let url = try fixture(imports: ["../engine.dll"])
        XCTAssertEqual(ExecutableRequirements.inspect(url, in: room).components, [])
    }

    func testDiagnosticRepairOnlyRecognizesKnownDependencies() {
        let output = "err:module:import_dll Library VCRUNTIME140_1.dll (which is needed) not found\nerr:module:import_dll Library vendor_private.dll (which is needed) not found"
        XCTAssertEqual(LaunchDiagnostics.missingComponents(output: output), ["vcrun2026"])
        XCTAssertEqual(LaunchDiagnostics.missingComponents(output: "Please install VCRUNTIME140.dll"), [])
    }
}
