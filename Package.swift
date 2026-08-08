// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexCanvas",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexCanvas", targets: ["CodexCanvas"]),
    ],
    targets: [
        .executableTarget(
            name: "CodexCanvas",
            path: "Sources/CodexCanvas"
        ),
        .testTarget(
            name: "CodexCanvasTests",
            dependencies: ["CodexCanvas"],
            path: "Tests/CodexCanvasTests"
        ),
    ]
)
