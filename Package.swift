// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeUsage",
            path: "Sources/ClaudeUsage",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
