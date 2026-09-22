// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NotchMate",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.5.1"),
    ],
    targets: [
        .executableTarget(
            name: "NotchMate",
            dependencies: [.product(name: "OpenAI", package: "OpenAI")],
            path: "Sources/NotchMate",
            swiftSettings: [.unsafeFlags(["-Onone"], .when(configuration: .debug))]
        )
    ]
)
