// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WinMacVirtual",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "WinMacVirtual",
            path: "Sources/WinMacVirtual"
        )
    ]
)
