// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ClaudeUsage",
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                // Sparkle.framework은 빌드 산출물 디렉토리에 실행 파일과 나란히 놓인다. 예전 빌드
                // 시스템은 @loader_path rpath를 자동으로 넣어 줬지만 Swift 6.4의 새 빌드 시스템
                // (.build/out)은 넣지 않아 `swift run`이 dyld "Library not loaded"로 죽는다.
                // 릴리스 .app은 scripts/package.sh가 @executable_path/../Frameworks를 따로 넣으므로
                // 이 값은 dev 실행 전용이고 번들에서는 그냥 통과된다.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path"]),
            ]
        ),
        .testTarget(
            name: "ClaudeUsageTests",
            dependencies: ["ClaudeUsage"],
            path: "Tests/ClaudeUsageTests"
        )
    ]
)
