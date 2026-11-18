// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zaslon",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Zaslon", path: "Sources/Zaslon")]
)
