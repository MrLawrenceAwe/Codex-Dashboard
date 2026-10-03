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
        .target(name: "DashboardKeychainProtocol"),
        .executableTarget(name: "CodexDashboardKeychainHelper", dependencies: ["DashboardKeychain", "DashboardKeychainProtocol"]),
        .executableTarget(
            name: "CodexDashboard",
            dependencies: ["DashboardKeychainProtocol"],
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
