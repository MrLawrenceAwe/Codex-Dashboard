// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexDashboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexDashboard", targets: ["CodexDashboard"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexDashboard",
            path: "Sources/CodexDashboard"
        ),
        .testTarget(
            name: "CodexDashboardTests",
            dependencies: ["CodexDashboard"],
            path: "Tests/CodexDashboardTests"
        ),
    ]
)
