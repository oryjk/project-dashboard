// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectDashboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ProjectDashboard"),
        .testTarget(name: "ProjectDashboardTests", dependencies: ["ProjectDashboard"])
    ]
)
