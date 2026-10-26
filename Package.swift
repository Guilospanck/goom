// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Goom",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Goom",
            path: "Sources/Goom",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
