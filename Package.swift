// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ControlLite",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ControlLite",
            targets: ["ControlLite"]
        )
    ],
    dependencies: [
        // 唯一的第三方依赖：原生在线更新组件，固定版本（见 AGENTS.md 与 THIRD_PARTY_NOTICES.md）。
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "ControlLite",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ControlLite",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                // App 包内的 Sparkle.framework 位于 Contents/Frameworks。
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "ControlLiteTests",
            dependencies: ["ControlLite"],
            path: "Tests/ControlLiteTests"
        )
    ]
)
