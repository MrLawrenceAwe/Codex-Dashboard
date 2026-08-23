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
            resources: [.copy("Resources/Dashboard")]
        ),
        .testTarget(
            name: "CodexDashboardTests",
            dependencies: ["CodexDashboard"],
            path: "Tests/CodexDashboardTests",
            resources: [.copy("VisualBaselines")]
        ),
    ]
)
