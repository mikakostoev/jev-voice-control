// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Jev",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Jev", path: "Sources/Jev")]
)
