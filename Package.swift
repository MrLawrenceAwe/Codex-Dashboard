// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexDashboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexDashboard", targets: ["CodexDashboard"]),
        .executable(name: "CodexDashboardKeychainHelper", targets: ["CodexDashboardKeychainHelper"]),
    ],
    targets: [
        .target(name: "DashboardKeychain"),
        .executableTarget(name: "CodexDashboardKeychainHelper", dependencies: ["DashboardKeychain"]),
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
