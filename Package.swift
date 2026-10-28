// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DiskMap",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "DiskMap", path: "Sources")]
)
