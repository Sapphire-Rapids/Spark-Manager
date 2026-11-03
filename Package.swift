// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SparkManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SparkManager", targets: ["SparkMonitor"])],
    dependencies: [.package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1")],
    targets: [
        .target(name: "CIOReport", linkerSettings: [.linkedLibrary("IOReport")]),
        .executableTarget(name: "SparkMonitor", dependencies: ["CIOReport", .product(name: "Citadel", package: "Citadel")], resources: [.copy("Resources/collector.py"), .copy("Resources/windows-collector.ps1"), .copy("Resources/windows-native.cs")]),
        .testTarget(name: "SparkMonitorTests", dependencies: ["SparkMonitor"])
    ]
)
